defmodule Phoenix.Channels.GenSocketClient do
  @moduledoc """
  Communication with a Phoenix Channels server.

  This module powers a process which can connect to a Phoenix Channels server and
  exchange messages with it. Currently, only websocket communication protocol is
  supported.

  The module is implemented as a behaviour. To use it, you need to implement the
  callback module. Then, you can invoke `start_link/5` to start the socket process.
  The communication with the server is then controlled from that process.

  The connection is not automatically established during the creation. Instead,
  the implementation can return `{:connect, state}` to try to establish the
  connection. As the result either `handle_connected/2` or  `handle_disconnected/2`
  callbacks will be invoked.

  To join a topic, `join/3` function can be used. Depending on the result, either
  `handle_joined/4` or `handle_join_error/4` will be invoked. A client can join
  multiple topics on the same socket. It is also possible to leave a topic using
  the `leave/3` function.

  Once a client has joined a topic, it can use `push/4` to send messages to the
  server. If the server directly replies to the message, it will be handled in
  the `handle_reply/5` callback.

  If a server sends an independent message (i.e. the one which is not a direct
  reply), the `handle_message/5` callback will be invoked.

  If the server closes the channel, the `handle_channel_closed/4` will be invoked.
  This will not close the socket connection, and the client can continue to
  communicate on other channels, or attempt to rejoin the channel.

  ## Sending messages over the socket

  As mentioned, you can use `join/3`, `push/4`, and `leave/3` to send messages to
  the server. All of these functions require the `transport` information as the
  first argument. This information is available in most of the callback functions.

  Functions will return `{:ok, ref}` if the message was sent successfully,
  or `{:error, reason}`, where `ref` is the Phoenix ref used to uniquely identify
  a message on a channel.

  Error responses are returned in following situations:

  - The client is not connected
  - Attempt to send a message on a non-joined channel
  - Attempt to leave a non-joined channel
  - Attempt to join the already joined channel

  Keep in mind that there's no guarantee that a message will arrive to the server.
  You need to implement your own communication protocol on top of Phoenix
  Channels to obtain such guarantees.

  ## Process structure and lifecycle

  The behaviour will internally start the websocket client in a separate child
  process. This means that the communication runs concurrently to any processing
  which takes place in the behaviour.

  The socket process will crash only if the websocket process crashes, which can
  be caused only by some bug in the websocket client library. If you want to
  survive this situation, you can simply trap exits in the socket process, by
  calling `Process.flag(:trap_exit, true)` in the `init/1` callback. In this case,
  a crash of the websocket client process will be treated as a disconnect event.

  The socket process never decides to stop on its own. If you want to stop it,
  you can simply return `{:stop, reason, state}` from any of the callback.
  """
  use GenServer

  @type transport_opts :: any
  @type socket_opts :: [
    serializer: module,
    transport_opts: transport_opts
  ]
  @type callback_state :: any
  @opaque transport :: %{
    transport_mod: module,
    transport_pid: pid | nil,
    message_refs: :ets.tab,
    serializer: module
  }
  @type topic :: String.t
  @type event :: String.t
  @type payload :: %{String.t => any}
  @type out_payload :: %{(String.t | atom) => any}
  @type ref :: pos_integer
  @type message :: %{topic: topic, event: event, payload: payload, ref: ref}
  @type encoded_message :: binary
  @type handler_response ::
    {:ok, callback_state} |
    {:connect, callback_state} |
    {:stop, reason::any, callback_state}

  @doc "Invoked when the process is created."
  @callback init(arg::any) ::
    {:connect, url::String.t, callback_state} |
    {:noconnect, url::String.t, callback_state} |
    :ignore |
    {:error, reason::any}


  # -------------------------------------------------------------------
  # Behaviour definition
  # -------------------------------------------------------------------

  @doc "Invoked after the client has successfully connected to the server."
  @callback handle_connected(transport, callback_state) :: handler_response

  @doc "Invoked after the client has been disconnected from the server."
  @callback handle_disconnected(reason::any, callback_state) :: handler_response

  @doc "Invoked after the client has successfully joined a topic."
  @callback handle_joined(topic, payload, transport, callback_state) :: handler_response

  @doc "Invoked if the server has refused a topic join request."
  @callback handle_join_error(topic, payload, transport, callback_state) :: handler_response

  @doc "Invoked after the server closes a channel."
  @callback handle_channel_closed(topic, payload, transport, callback_state) :: handler_response

  @doc "Invoked when a message from the server arrives."
  @callback handle_message(topic, event, payload, transport, callback_state) :: handler_response

  @doc "Invoked when the server replies to a message sent by the client."
  @callback handle_reply(topic, ref, payload, transport, callback_state) :: handler_response

  @doc "Invoked to handle an Erlang message."
  @callback handle_info(message::any, transport, callback_state) :: handler_response

  @doc "Invoked to handle Erlang GenServer calls."
  @callback handle_call(message::any, transport, callback_state) :: handler_response


  # -------------------------------------------------------------------
  # API functions
  # -------------------------------------------------------------------

  @doc "Starts the socket process."
  @spec start_link(callback::module, transport_mod::module, any, socket_opts, GenServer.options) ::
      GenServer.on_start
  def start_link(callback, transport_mod, arg, socket_opts \\ [], gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, {callback, transport_mod, arg, socket_opts}, gen_server_opts)
  end

  @doc "Joins the topic."
  @spec join(transport, topic, out_payload) :: {:ok, ref} | {:error, reason::any}
  def join(transport, topic, payload \\ %{}),
    do: push(transport, topic, "phx_join", payload)

  @doc "Leaves the topic."
  @spec leave(transport, topic, out_payload) :: {:ok, ref} | {:error, reason::any}
  def leave(transport, topic, payload \\ %{}),
    do: push(transport, topic, "phx_leave", payload)

  @doc "Pushes a message to the topic."
  @spec push(transport, topic, event, out_payload) :: {:ok, ref} | {:error, reason::any}
  def push(%{transport_pid: nil}, _topic, _event, _payload), do: {:error, :disconnected}
  def push(transport, topic, event, payload) do
    ref = next_ref(topic, transport.message_refs)
    cond do
      # first message on a channel must always be a join
      event != "phx_join" and ref == 1 ->
        :ets.delete(transport.message_refs, topic)
        {:error, :not_joined}
      # join must always be a first message
      event == "phx_join" and ref > 1 ->
        {:error, :already_joined}
      true ->
        frame = transport.serializer.encode_message(%{topic: topic, event: event, payload: payload, ref: ref})
        transport.transport_mod.push(transport.transport_pid, frame)
        {:ok, ref}
    end
  end


  # -------------------------------------------------------------------
  # API for transport (websocket client)
  # -------------------------------------------------------------------

  @doc "Notifies the socket process that the connection has been established."
  @spec notify_connected(GenServer.server) :: :ok
  def notify_connected(socket),
    do: GenServer.cast(socket, :notify_connected)

  @doc "Notifies the socket process about a disconnect."
  @spec notify_disconnected(GenServer.server, any) :: :ok
  def notify_disconnected(socket, reason),
    do: GenServer.cast(socket, {:notify_disconnected, reason})

  @doc "Forwards a received message to the socket process."
  @spec notify_message(GenServer.server, binary) :: :ok
  def notify_message(socket, message),
    do: GenServer.cast(socket, {:notify_message, message})


  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @doc false
  def init({callback, transport_mod, arg, socket_opts}) do
    case callback.init(arg) do
      {action, url, callback_state} when action in [:connect, :noconnect] ->
        {:ok,
          maybe_connect(action, %{
            url: url,
            transport_mod: transport_mod,
            transport_opts: Keyword.get(socket_opts, :transport_opts, []),
            serializer: Keyword.get(socket_opts, :serializer, Phoenix.Channels.GenSocketClient.Serializer.Json),
            callback: callback,
            callback_state: callback_state,
            transport_pid: nil,
            transport_mref: nil,
            message_refs: :ets.new(:message_refs, [:private, :set])
          })
        }
      other -> other
    end
  end

  @doc false
  def handle_cast(:notify_connected, state) do
    invoke_callback(state, :handle_connected, [transport(state)])
  end
  def handle_cast({:notify_disconnected, reason}, state) do
    invoke_callback(reinit(state), :handle_disconnected, [reason])
  end
  def handle_cast({:notify_message, encoded_message}, state) do
    decoded_message = state.serializer.decode_message(encoded_message)
    handle_message(decoded_message, state)
  end

  @doc false
  def handle_info(
        {:DOWN, transport_mref, :process, _, reason},
        %{transport_mref: transport_mref} = state
      ) do
    invoke_callback(reinit(state), :handle_disconnected, [{:transport_down, reason}])
  end
  def handle_info(message, state) do
    invoke_callback(state, :handle_info, [message, transport(state)])
  end

  def handle_call(message, _from, state) do
    {callback_response, callback_state} = apply(state.callback, :handle_call, [message, transport(state), state.callback_state])
    {:reply, callback_response, %{state | callback_state: callback_state}}
  end

  # -------------------------------------------------------------------
  # Handling of Phoenix messages
  # -------------------------------------------------------------------

  # server replied to a join message (recognized by ref 1 which is the first message on the topic)
  defp handle_message(%{event: "phx_reply", ref: 1, payload: payload, topic: topic}, state) do
    case payload["status"] do
      "ok" ->
        invoke_callback(state, :handle_joined, [topic, payload["response"], transport(state)])
      "error" ->
        :ets.delete(state.message_refs, topic)
        invoke_callback(state, :handle_join_error, [topic, payload["response"], transport(state)])
    end
  end
  # server replied to a non-join message
  defp handle_message(%{event: "phx_reply", ref: ref, payload: payload, topic: topic}, state) do
    invoke_callback(state, :handle_reply, [topic, ref, payload, transport(state)])
  end
  # channel has been closed (phx_close) or crashed (phx_error) on the server
  defp handle_message(%{event: event, payload: payload, topic: topic}, state)
      when event in ["phx_close", "phx_error"] do
    :ets.delete(state.message_refs, topic)
    invoke_callback(state, :handle_channel_closed, [topic, payload, transport(state)])
  end
  # other messages from the server
  defp handle_message(%{event: event, payload: payload, topic: topic}, state) do
    invoke_callback(state, :handle_message, [topic, event, payload, transport(state)])
  end


  # -------------------------------------------------------------------
  # Internal functions
  # -------------------------------------------------------------------

  defp maybe_connect(:connect, state), do: connect(state)
  defp maybe_connect(:noconnect, state), do: state

  defp connect(%{transport_pid: nil} = state) do
    {:ok, transport_pid} = state.transport_mod.start_link(state.url, state.transport_opts)
    transport_mref = Process.monitor(transport_pid)
    %{state | transport_pid: transport_pid, transport_mref: transport_mref}
  end

  defp reinit(state) do
    :ets.delete_all_objects(state.message_refs)
    if (state.transport_mref != nil), do: Process.demonitor(state.transport_mref, [:flush])
    %{state | transport_pid: nil, transport_mref: nil}
  end

  defp transport(state),
    do: Map.take(state, [:transport_mod, :transport_pid, :message_refs, :serializer])

  defp next_ref(topic, message_refs),
    do: :ets.update_counter(message_refs, topic, 1, {topic, 0})

  defp invoke_callback(state, function, args) do
    callback_response = apply(state.callback, function, args ++ [state.callback_state])
    handle_callback_response(callback_response, state)
  end

  defp handle_callback_response({:ok, callback_state}, state),
    do: {:noreply, %{state | callback_state: callback_state}}
  defp handle_callback_response({:connect, callback_state}, state),
    do: {:noreply, connect(%{state | callback_state: callback_state})}
  defp handle_callback_response({:stop, reason, callback_state}, state),
    do: {:stop, reason, %{state | callback_state: callback_state}}
end
