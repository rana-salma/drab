defmodule Drab do
  @moduledoc """
  Drab allows to query and manipulate the User Interface directly from the Phoenix server backend.

  To enable it on the specific page you must find its controller and 
  enable Drab by `use Drab.Controller` there:

      defmodule DrabExample.PageController do
        use Example.Web, :controller
        use Drab.Controller 

        def index(conn, _params) do
          render conn, "index.html"
        end
      end   

  Notice that it will enable Drab on all the pages generated by `DrabExample.PageController`.

  All Drab functions (callbacks and event handlers) should be placed in a module called 'commander'. It is very
  similar to controller, but it does not render any pages - it works with the live page instead. Each controller with 
  enabled Drab should have the corresponding commander.

      defmodule DrabExample.PageCommander do
        use Drab.Commander

        onload :page_loaded

        # Drab Callbacks
        def page_loaded(socket) do
          socket |> update(:html, set: "Welcome to Phoenix+Drab!", on: "div.jumbotron h2")
          socket |> update(:html, 
                set: "Please visit <a href='https://tg.pl/drab'>Drab</a> page for more examples and description",
                on:  "div.jumbotron p.lead")
        end

        # Drab Events
        def button_clicked(socket, dom_sender) do
          socket |> update(:text, set: "alread clicked", on: this(dom_sender))
        end

      end

  Drab treats browser page as a database, allows you to read and change the data there. Please refer to `Drab.Query` documentation to 
  find out how `Drab.Query.select/2` or `Drab.Query.update/2` works.

  ## Debugging Drab in IEx

  When started with iex (`iex -S mix phoenix.server`) Drab shows the helpful message on how to debug its functions:

          Started Drab for /drab/docs, handling events in DrabPoc.DocsCommander
          You may debug Drab functions in IEx by copy/paste the following:
      import Drab.{Core, Query, Modal, Waiter}
      socket = Drab.get_socket(pid("0.443.0"))

          Examples:
      socket |> select(:htmls, from: "h4")
      socket |> exec_js("alert('hello from IEx!')")
      socket |> alert("Title", "Sure?", buttons: [ok: "Azaliż", cancel: "Poniechaj"])

  All you need to do is to copy/paste the line with `socket = ...` and now you can run Drab function directly
  from IEx, observing the results on the running browser in the realtime.


  ## Handling Exceptions

  Drab intercepts all exceptions from event handler function and let it die, but before it presents the error message 
  in the logs, and, for development environment, on the page. For production, it shows just an alert with 
  the generic error. 

  By default it is just an alert(), but you can easly override it by creating the template in the
  `priv/templates/drab/drab.handler_error.prod.js` folder with your own javascript presenting the message.

  ## Modules

  Drab is modular. You may choose which modules to use in the specific Commander by using `:module` option
  in `use Drab.Commander` directive. By default, `Drab.Query` and `Drab.Modal` are loaded, but you may override it using 
  options with `use Drab.Commander` directive.

  Every module must have the corresponding javascript template, which is added to the client code in case the module is loaded.
  """

  require Logger
  use GenServer

  @type t :: %Drab{store: map, session: map, commander: atom, socket: Phoenix.Socket.t, priv: map}

  defstruct store: %{}, session: %{}, commander: nil, socket: nil, priv: %{}

  @doc false
  def start_link(socket) do
    GenServer.start_link(__MODULE__, 
      %Drab{commander: Drab.get_commander(socket)})
  end

  @doc false
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @doc false
  def terminate(_reason, %Drab{store: store, session: session, commander: commander} = state) do
    if commander.__drab__().ondisconnect do
      # TODO: timeout
      :ok = apply(commander, 
            commander_config(commander).ondisconnect, 
            [store, session])
    end
    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, :normal}, state) when pid != self() do
    # ignore exits of the subprocesses
    # Logger.debug "************** #{inspect pid} process exit normal"
    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, :killed}, state) when pid != self() do
    failed(state.socket, %RuntimeError{message: "Drab Process #{inspect(pid)} has been killed."})
    {:noreply, state}
  end

  @doc false
  def handle_info({:EXIT, pid, {reason, stack}}, state) when pid != self() do
    # subprocess died
    Logger.error """
    Drab Process #{inspect(pid)} died because of #{inspect(reason)}
    #{Exception.format_stacktrace(stack)}
    """
    {:noreply, state}
  end

  @doc false
  def handle_cast({:onconnect, socket, payload}, %Drab{commander: commander} = state) do
    # TODO: there is an issue when the below failed and client tried to reconnect again and again
    # tasks = [Task.async(fn -> Drab.Core.save_session(socket, Drab.Core.session(socket)) end), 
    #          Task.async(fn -> Drab.Core.save_store(socket, Drab.Core.store(socket)) end)]
    # Enum.each(tasks, fn(task) -> Task.await(task) end)

    # Logger.debug "******"
    # Logger.debug inspect(Drab.Core.session(socket))

    # IO.inspect payload

    socket  = transform_socket(payload, socket, state)

    Drab.Core.save_session(socket, Drab.Core.session(socket))
    Drab.Core.save_store(socket, Drab.Core.store(socket))
    Drab.Core.save_socket(socket)

    onconnect = commander_config(commander).onconnect
    handle_callback(socket, commander, onconnect) 

    {:noreply, state}
  end

  @doc false
  def handle_cast({:onload, socket}, %Drab{commander: commander} = state) do
    # {_, socket} = transform_payload_and_socket(payload, socket, commander_module)
    # IO.inspect state

    onload = commander_config(commander).onload
    handle_callback(socket, commander, onload) #returns socket
    {:noreply, state}
  end

  # casts for update values from the state
  Enum.each([:store, :session, :socket, :priv], fn name ->
    msg_name = "set_#{name}" |> String.to_atom()
      @doc false
      def handle_cast({unquote(msg_name), value}, state) do
        new_state = Map.put(state, unquote(name), value)
        {:noreply, new_state}
      end
  end)

  @doc false
  # any other cast is an event handler
  def handle_cast({event_name, socket, payload, event_handler_function, reply_to}, state) do
    handle_event(socket, event_name, event_handler_function, payload, reply_to, state)
  end

  # calls for get values from the state
  Enum.each([:store, :session, :socket, :priv], fn name ->
    msg_name = "get_#{name}" |> String.to_atom()
      @doc false
      def handle_call(unquote(msg_name), _from, state) do
        value = Map.get(state, unquote(name))
        {:reply, value, state}
      end
  end)

  defp handle_callback(socket, commander, callback) do
    if callback do
      # TODO: rethink the subprocess strategies - now it is just spawn_link
      spawn_link fn ->
        try do 
          apply(commander, callback, [socket])
        rescue e ->
          failed(socket, e)
        end
      end
    end
    socket
  end

  defp transform_payload(payload, state) do
    all_modules = DrabModule.all_modules_for(state.commander.__drab__().modules)

    # transform payload via callbacks in DrabModules
    Enum.reduce(all_modules, payload, fn(m, p) ->
      m.transform_payload(p, state)
    end)
  end

  defp transform_socket(payload, socket, state) do
    all_modules = DrabModule.all_modules_for(state.commander.__drab__().modules)

    # transform socket via callbacks
    Enum.reduce(all_modules, socket, fn(m, s) ->
      m.transform_socket(s, payload, state)
    end)  
  end

  defp handle_event(socket, _event_name, event_handler_function, payload, reply_to, 
                                        %Drab{commander: commander_module} = state) do
    # TODO: rethink the subprocess strategies - now it is just spawn_link
    spawn_link fn -> 
      try do
        check_handler_existence!(commander_module, event_handler_function)

        event_handler = String.to_existing_atom(event_handler_function)
        payload = Map.delete(payload, "event_handler_function")

        payload = transform_payload(payload, state)
        socket  = transform_socket(payload, socket, state)

        commander_cfg = commander_config(commander_module)

        # run before_handlers first
        returns_from_befores = Enum.map(callbacks_for(event_handler, commander_cfg.before_handler), 
          fn callback_handler ->
            apply(commander_module, callback_handler, [socket, payload])
          end)

        # if ANY of them fail (return false or nil), do not proceed
        unless Enum.any?(returns_from_befores, &(!&1)) do
          # run actuall event handler
          returned_from_handler = apply(commander_module, event_handler, [socket, payload])

          Enum.map(callbacks_for(event_handler, commander_cfg.after_handler), 
            fn callback_handler ->
              apply(commander_module, callback_handler, [socket, payload, returned_from_handler])
            end)
        end
      
      rescue e ->
        failed(socket, e)
      after
        # push reply to the browser, to re-enable controls
        push_reply(socket, reply_to, commander_module, event_handler_function)
      end
    end

    {:noreply, state}
  end

  defp check_handler_existence!(commander_module, handler) do
    unless function_exists?(commander_module, handler) do
      raise "Drab can't find the handler: \"#{commander_module}.#{handler}/2\"."
    end    
  end

  defp failed(socket, e) do
    error = """
    Drab Handler failed with the following exception:
    #{Exception.format_banner(:error, e)}
    #{Exception.format_stacktrace(System.stacktrace())}
    """
    Logger.error error

    if socket do
      js = Drab.Template.render_template(
        "drab.handler_error.#{Atom.to_string(Mix.env)}.js", 
        message: Drab.Core.encode_js(error))
      {:ok, _} = Drab.Core.exec_js(socket, js)
    end
  end

  defp push_reply(socket, reply_to, _, _) do
    Phoenix.Channel.push(socket, "event", %{
      finished: reply_to
    })
  end

  @doc false
  # Returns the list of callbacks (before_handler, after_handler) defined in handler_config
  def callbacks_for(_, []) do
    []
  end

  @doc false
  def callbacks_for(event_handler_function, handler_config) do
    #:uppercase, [{:run_before_each, []}, {:run_before_uppercase, [only: [:uppercase]]}]
    Enum.map(handler_config, fn {callback_name, callback_filter} -> 
      case callback_filter do
        [] -> callback_name
        [only: handlers] -> 
          if event_handler_function in handlers, do: callback_name, else: false
        [except: handlers] -> 
          if event_handler_function in handlers, do: false, else: callback_name
        _ -> false
      end
    end) |> Enum.filter(&(&1))
  end

  # setter and getter functions
  Enum.each([:store, :session, :socket, :priv], fn name ->
    get_name = "get_#{name}" |> String.to_atom()
    update_name = "set_#{name}" |> String.to_atom()

    @doc false
    def unquote(get_name)(pid) do
      GenServer.call(pid, unquote(get_name))
    end

    @doc false
    def unquote(update_name)(pid, new_value) do
      GenServer.cast(pid, {unquote(update_name), new_value})
    end
  end)

  @doc false
  def function_exists?(module_name, function_name) do
    module_name.__info__(:functions) 
      |> Enum.map(fn {f, _} -> Atom.to_string(f) end)
      |> Enum.member?(function_name)
  end

  @doc false
  def push_and_wait_for_response(socket, pid, message, payload \\ [], options \\ []) do
    push(socket, pid, message, payload)
    timeout = options[:timeout] || Drab.Config.get(:browser_response_timeout)
    receive do
      {:got_results_from_client, status, reply} -> 
        {status, reply}
      after timeout -> 
        {:error, "timed out after #{timeout} ms."}
    end    
  end

  @doc false
  def push_and_wait_forever(socket, pid, message, payload \\ []) do
    # TODO: timeout for modals
    push(socket, pid, message, payload)
    receive do
      {:got_results_from_client, status, reply} -> 
        {status, reply}
    end    
  end

  @doc false
  def push(socket, pid, message, payload \\ []) do
    do_push_or_broadcast(socket, pid, message, payload, &Phoenix.Channel.push/3)
  end

  @doc false
  def broadcast(socket, pid, message, payload \\ []) do
    do_push_or_broadcast(socket, pid, message, payload, &Phoenix.Channel.broadcast/3)
  end

  defp do_push_or_broadcast(socket, pid, message, payload, function) do
    m = payload |> Enum.into(%{}) |> Map.merge(%{sender: tokenize(socket, pid)})
    function.(socket, message,  m)    
  end

  @doc false
  def tokenize(socket, what, salt \\ "drab token") do
    Phoenix.Token.sign(socket, salt, what)
  end

  @doc false
  def detokenize(socket, token, salt \\ "drab token") do
    case Phoenix.Token.verify(socket, salt, token) do
      {:ok, detokenized} -> 
        detokenized
      {:error, reason} -> 
        raise "Can't verify the token `#{salt}`: #{inspect(reason)}" # let it die    
    end
  end

  # returns the commander name for the given controller (assigned in socket)
  @doc false
  def get_commander(socket) do
    controller = socket.assigns.__controller
    controller.__drab__()[:commander]
  end

  # returns the controller name used with the socket
  @doc false
  def get_controller(socket) do
    socket.assigns.__controller
  end

  # returns the view name used with the socket
  @doc false
  def get_view(socket) do
    controller = socket.assigns.__controller
    controller.__drab__()[:view]
  end

  # returns the drab_pid from socket
  @doc "Extract Drab PID from the socket"
  def pid(socket) do
    socket.assigns.__drab_pid
  end

  # if module is commander or controller with drab enabled, it has __drab__/0 function with Drab configuration
  defp commander_config(module) do
    module.__drab__()
  end

  @doc false
  def config() do
    Drab.Config.config()
  end

end
