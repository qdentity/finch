defmodule Finch.Conn do
  @moduledoc false

  alias Mint.HTTP1
  alias Finch.Telemetry
  alias Finch.SSL

  def new(scheme, host, port, opts, parent) do
    %{
      scheme: scheme,
      host: host,
      port: port,
      opts: opts.conn_opts,
      parent: parent,
      last_checkin: System.monotonic_time(),
      max_idle_time: opts.conn_max_idle_time,
      mint: nil
    }
  end

  def connect(%{mint: mint} = conn) when not is_nil(mint) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port
    }

    Telemetry.event(:reused_connection, %{}, meta)
    {:ok, conn}
  end

  def connect(%{mint: nil} = conn) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port
    }

    start_time = Telemetry.start(:connect, meta)

    # We have to use Mint's top-level connect function or else proxying won't work. So we
    # force the connection to use http1 and call it in this roundabout way.
    conn_opts = Keyword.merge(conn.opts, mode: :passive, protocols: [:http1])

    case Mint.HTTP.connect(conn.scheme, conn.host, conn.port, conn_opts) do
      {:ok, mint} ->
        Telemetry.stop(:connect, start_time, meta)
        SSL.maybe_log_secrets(conn.scheme, conn_opts, mint)
        {:ok, %{conn | mint: mint}}

      {:error, error} ->
        meta = Map.put(meta, :error, error)
        Telemetry.stop(:connect, start_time, meta)
        {:error, conn, error}
    end
  end

  def transfer(conn, pid) do
    case HTTP1.controlling_process(conn.mint, pid) do
      # HTTP1.controlling_process causes a side-effect, but it doesn't actually
      # change the conn, so we can ignore the value returned above.
      {:ok, _} -> {:ok, conn}
      {:error, error} -> {:error, conn, error}
    end
  end

  def open?(%{mint: nil}), do: false
  def open?(%{mint: mint}), do: HTTP1.open?(mint)

  def idle_time(conn, unit \\ :native) do
    idle_time = System.monotonic_time() - conn.last_checkin

    System.convert_time_unit(idle_time, :native, unit)
  end

  def reusable?(%{max_idle_time: :infinity}, _idle_time), do: true
  def reusable?(%{max_idle_time: max_idle_time}, idle_time), do: idle_time <= max_idle_time

  def set_mode(conn, mode) when mode in [:active, :passive] do
    case HTTP1.set_mode(conn.mint, mode) do
      {:ok, mint} -> {:ok, %{conn | mint: mint}}
      _ -> {:error, "Connection is dead"}
    end
  end

  def discard(%{mint: nil}, _), do: :unknown

  def discard(conn, message) do
    case HTTP1.stream(conn.mint, message) do
      {:ok, mint, _responses} -> {:ok, %{conn | mint: mint}}
      {:error, _, reason, _} -> {:error, reason}
      :unknown -> :unknown
    end
  end

  def request(%{mint: nil} = conn, _, _, _, _, _), do: {:error, conn, "Could not connect"}

  def request(conn, req, acc, fun, receive_timeout, idle_time) do
    full_path = Finch.Request.request_path(req)

    metadata = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      path: full_path,
      method: req.method
    }

    extra_measurements = %{idle_time: idle_time}

    start_time = Telemetry.start(:request, metadata, extra_measurements)

    try do
      case HTTP1.request(conn.mint, req.method, full_path, req.headers, stream_or_body(req.body)) do
        {:ok, mint, ref} ->
          case maybe_stream_request_body(mint, ref, req.body, receive_timeout) do
            {:ok, mint} ->
              Telemetry.stop(:request, start_time, metadata, extra_measurements)
              start_time = Telemetry.start(:response, metadata, extra_measurements)
              response = receive_response([], acc, fun, mint, ref, receive_timeout)
              handle_response(response, conn, metadata, start_time, extra_measurements)

            {:error, mint, error} ->
              handle_request_error(
                conn,
                mint,
                error,
                metadata,
                start_time,
                extra_measurements
              )
          end

        {:error, mint, error} ->
          handle_request_error(conn, mint, error, metadata, start_time, extra_measurements)
      end
    catch
      kind, error ->
        close(conn)
        Telemetry.exception(:response, start_time, kind, error, __STACKTRACE__, metadata)
        :erlang.raise(kind, error, __STACKTRACE__)
    end
  end

  defp stream_or_body({:stream, _}), do: :stream
  defp stream_or_body(body), do: body

  defp handle_request_error(conn, mint, error, metadata, start_time, extra_measurements) do
    metadata = Map.put(metadata, :error, error)
    Telemetry.stop(:request, start_time, metadata, extra_measurements)
    {:error, %{conn | mint: mint}, error}
  end

  defp maybe_stream_request_body(mint, ref, {:stream, stream}, _timeout) do
    with {:ok, mint} <- stream_request_body(mint, ref, stream) do
      HTTP1.stream_request_body(mint, ref, :eof)
    end
  end

  defp maybe_stream_request_body(mint, _, _, _), do: {:ok, mint}

  defp stream_request_body(mint, ref, stream) do
    Enum.reduce_while(stream, {:ok, mint}, fn
      chunk, {:ok, mint} -> {:cont, HTTP1.stream_request_body(mint, ref, chunk)}
      _chunk, error -> {:halt, error}
    end)
  end

  def close(%{mint: nil} = conn), do: conn

  def close(conn) do
    {:ok, mint} = HTTP1.close(conn.mint)
    %{conn | mint: mint}
  end

  defp handle_response(response, conn, metadata, start_time, extra_measurements) do
    case response do
      {:ok, mint, acc} ->
        Telemetry.stop(:response, start_time, metadata, extra_measurements)
        {:ok, %{conn | mint: mint}, acc}

      {:error, mint, error} ->
        metadata = Map.put(metadata, :error, error)
        Telemetry.stop(:response, start_time, metadata, extra_measurements)
        {:error, %{conn | mint: mint}, error}
    end
  end

  defp receive_response([], acc, fun, mint, ref, timeout) do
    case HTTP1.recv(mint, 0, timeout) do
      {:ok, mint, entries} ->
        receive_response(entries, acc, fun, mint, ref, timeout)

      {:error, mint, error, _responses} ->
        {:error, mint, error}
    end
  end

  defp receive_response([entry | entries], acc, fun, mint, ref, timeout) do
    case entry do
      {:status, ^ref, value} ->
        receive_response(entries, fun.({:status, value}, acc), fun, mint, ref, timeout)

      {:headers, ^ref, value} ->
        receive_response(entries, fun.({:headers, value}, acc), fun, mint, ref, timeout)

      {:data, ^ref, value} ->
        receive_response(entries, fun.({:data, value}, acc), fun, mint, ref, timeout)

      {:done, ^ref} ->
        {:ok, mint, acc}

      {:error, ^ref, error} ->
        {:error, mint, error}
    end
  end
end
