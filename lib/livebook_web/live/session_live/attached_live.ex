defmodule LivebookWeb.SessionLive.AttachedLive do
  use LivebookWeb, :live_view

  alias Livebook.{Session, Runtime}

  @impl true
  def mount(_params, %{"session" => session, "current_runtime" => current_runtime}, socket) do
    unless Livebook.Config.runtime_enabled?(Livebook.Runtime.Attached) do
      raise "runtime module not allowed"
    end

    if connected?(socket) do
      Session.subscribe(session.id)
    end

    {:ok,
     assign(socket,
       session: session,
       current_runtime: current_runtime,
       error_message: nil,
       data: initial_data(current_runtime)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-col space-y-5">
      <div :if={@error_message} class="error-box">
        <%= @error_message %>
      </div>
      <p class="text-gray-700">
        Connect the session to an already running node
        and evaluate code in the context of that node.
        Thanks to this approach you can work with
        an arbitrary Elixir runtime.
        Make sure to give the node a name and a cookie, for example:
      </p>
      <div class="text-gray-700 markdown">
        <%= if longname = Livebook.Config.longname() do %>
          <pre><code>iex --name test@<%= longname %> --cookie mycookie</code></pre>
        <% else %>
          <pre><code>iex --sname test --cookie mycookie</code></pre>
        <% end %>
      </div>
      <p class="text-gray-700">
        Then enter the connection information below:
      </p>
      <.form
        :let={f}
        for={@data}
        as={:data}
        phx-submit="init"
        phx-change="validate"
        autocomplete="off"
        spellcheck="false"
      >
        <div class="flex flex-col space-y-4">
          <.text_field field={f[:name]} label="Name" placeholder={name_placeholder()} />
          <.text_field field={f[:cookie]} label="Cookie" placeholder="mycookie" />
        </div>
        <button class="mt-5 button-base button-blue" type="submit" disabled={not data_valid?(@data)}>
          <%= if(matching_runtime?(@current_runtime, @data), do: "Reconnect", else: "Connect") %>
        </button>
      </.form>
    </div>
    """
  end

  defp matching_runtime?(%Runtime.Attached{} = runtime, data) do
    initial_data(runtime) == data
  end

  defp matching_runtime?(_runtime, _data), do: false

  @impl true
  def handle_event("validate", %{"data" => data}, socket) do
    {:noreply, assign(socket, data: data)}
  end

  def handle_event("init", %{"data" => data}, socket) do
    node = String.to_atom(data["name"])
    cookie = String.to_atom(data["cookie"])

    runtime = Runtime.Attached.new(node, cookie)

    case Runtime.connect(runtime) do
      {:ok, runtime} ->
        Session.set_runtime(socket.assigns.session.pid, runtime)
        {:noreply, assign(socket, data: initial_data(runtime), error_message: nil)}

      {:error, message} ->
        {:noreply,
         assign(socket,
           data: data,
           error_message: Livebook.Utils.upcase_first(message)
         )}
    end
  end

  @impl true
  def handle_info({:operation, {:set_runtime, _pid, runtime}}, socket) do
    {:noreply, assign(socket, current_runtime: runtime)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp initial_data(%Runtime.Attached{node: node, cookie: cookie}) do
    %{
      "name" => Atom.to_string(node),
      "cookie" => Atom.to_string(cookie)
    }
  end

  defp initial_data(_runtime), do: %{"name" => "", "cookie" => ""}

  defp data_valid?(data) do
    data["name"] != "" and data["cookie"] != ""
  end

  defp name_placeholder do
    if longname = Livebook.Config.longname(), do: "test@#{longname}", else: "test"
  end
end
