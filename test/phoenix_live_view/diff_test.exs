defmodule Phoenix.LiveView.DiffTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveView, only: [sigil_L: 2]

  alias Phoenix.LiveView.{Socket, Diff, Rendered, Component}

  def basic_template(assigns) do
    ~L"""
    <div>
      <h2>It's <%= @time %></h2>
      <%= @subtitle %>
    </div>
    """
  end

  def literal_template(assigns) do
    ~L"""
    <div>
      <%= @title %>
      <%= "<div>" %>
    </div>
    """
  end

  def comprehension_template(assigns) do
    ~L"""
    <div>
      <h1><%= @title %></h1>
      <%= for name <- @names do %>
        <br/><%= name %>
      <% end %>
    </div>
    """
  end

  @nested %Rendered{
    static: ["<h2>...", "\n<span>", "</span>\n"],
    dynamic: [
      "hi",
      %Rendered{
        static: ["s1", "s2", "s3"],
        dynamic: ["abc"],
        fingerprint: 456
      },
      nil,
      %Rendered{
        static: ["s1", "s2"],
        dynamic: ["efg"],
        fingerprint: 789
      }
    ],
    fingerprint: 123
  }

  defp render(
         rendered,
         fingerprints \\ Diff.new_fingerprints(),
         components \\ Diff.new_components()
       ) do
    Diff.render(%Socket{endpoint: __MODULE__, fingerprints: fingerprints}, rendered, components)
  end

  describe "full renders without fingerprints" do
    test "basic template" do
      rendered = basic_template(%{time: "10:30", subtitle: "Sunny"})
      {socket, full_render, _} = render(rendered)

      assert full_render == %{
               0 => "10:30",
               1 => "Sunny",
               :static => ["<div>\n  <h2>It's ", "</h2>\n  ", "\n</div>\n"]
             }

      assert socket.fingerprints == {rendered.fingerprint, %{}}
    end

    test "template with literal" do
      rendered = literal_template(%{title: "foo"})
      {socket, full_render, _} = render(rendered)

      assert full_render ==
               %{0 => "foo", 1 => "&lt;div&gt;", :static => ["<div>\n  ", "\n  ", "\n</div>\n"]}

      assert socket.fingerprints == {rendered.fingerprint, %{}}
    end

    test "nested %Renderered{}'s" do
      {socket, full_render, _} = render(@nested)

      assert full_render ==
               %{
                 :static => ["<h2>...", "\n<span>", "</span>\n"],
                 0 => "hi",
                 1 => %{0 => "abc", :static => ["s1", "s2", "s3"]},
                 3 => %{0 => "efg", :static => ["s1", "s2"]}
               }

      assert socket.fingerprints == {123, %{3 => {789, %{}}, 1 => {456, %{}}}}
    end

    test "comprehensions" do
      rendered = comprehension_template(%{title: "Users", names: ["phoenix", "elixir"]})
      {socket, full_render, _} = render(rendered)

      assert full_render == %{
               0 => "Users",
               :static => ["<div>\n  <h1>", "</h1>\n  ", "\n</div>\n"],
               1 => %{
                 static: ["\n    <br/>", "\n  "],
                 dynamics: [["phoenix"], ["elixir"]]
               }
             }

      assert socket.fingerprints == {rendered.fingerprint, %{1 => :comprehension}}
    end
  end

  describe "diffed render with fingerprints" do
    test "basic template skips statics for known fingerprints" do
      rendered = basic_template(%{time: "10:30", subtitle: "Sunny"})
      {socket, full_render, _} = render(rendered, {rendered.fingerprint, %{}})

      assert full_render == %{0 => "10:30", 1 => "Sunny"}
      assert socket.fingerprints == {rendered.fingerprint, %{}}
    end

    test "renders nested %Renderered{}'s" do
      tree = {123, %{3 => {789, %{}}, 1 => {456, %{}}}}
      {socket, diffed_render, _} = render(@nested, tree)

      assert diffed_render == %{0 => "hi", 1 => %{0 => "abc"}, 3 => %{0 => "efg"}}
      assert socket.fingerprints == tree
    end

    test "detects change in nested fingerprint" do
      old_tree = {123, %{3 => {789, %{}}, 1 => {100_001, %{}}}}
      {socket, diffed_render, _} = render(@nested, old_tree)

      assert diffed_render ==
               %{0 => "hi", 3 => %{0 => "efg"}, 1 => %{0 => "abc", :static => ["s1", "s2", "s3"]}}

      assert socket.fingerprints == {123, %{3 => {789, %{}}, 1 => {456, %{}}}}
    end

    test "detects change in root fingerprint" do
      old_tree = {99999, %{}}
      {socket, diffed_render, _} = render(@nested, old_tree)

      assert diffed_render == %{
               0 => "hi",
               1 => %{0 => "abc", :static => ["s1", "s2", "s3"]},
               3 => %{0 => "efg", :static => ["s1", "s2"]},
               :static => ["<h2>...", "\n<span>", "</span>\n"]
             }

      assert socket.fingerprints == {123, %{3 => {789, %{}}, 1 => {456, %{}}}}
    end
  end

  def component_template(assigns) do
    ~L"""
    <div>
      <%= @component %>
    </div>
    """
  end

  alias __MODULE__.MyComponent
  alias __MODULE__.SameComponent

  for module <- [MyComponent, SameComponent] do
    defmodule module do
      use Phoenix.LiveComponent

      def mount(socket) do
        send(self(), {:mount, socket})
        {:ok, assign(socket, hello: "world")}
      end

      def update(assigns, socket) do
        send(self(), {:update, assigns, socket})
        {:ok, assign(socket, assigns)}
      end

      def render(assigns) do
        send(self(), :render)

        ~L"""
        FROM <%= @from %> <%= @hello %>
        """
      end
    end
  end

  describe "components" do
    test "on mount" do
      component = %Component{id: "hello", assigns: %{from: :component}, component: MyComponent}
      rendered = component_template(%{component: component})
      {socket, full_render, components} = render(rendered)

      assert full_render == %{
               0 => 0,
               :components => %{
                 0 => %{
                   0 => "component",
                   1 => "world",
                   :static => ["FROM ", " ", "\n"]
                 }
               },
               :static => ["<div>\n  ", "\n</div>\n"]
             }

      assert socket.fingerprints == {rendered.fingerprint, %{}}

      {_, cids_to_ids, 1} = components
      assert cids_to_ids[0] == "hello"

      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :component}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      refute_received _
    end

    test "on update without render" do
      component = %Component{id: "hello", assigns: %{from: :component}, component: MyComponent}
      rendered = component_template(%{component: component})
      {previous_socket, _, previous_components} = render(rendered)

      {socket, full_render, components} =
        render(rendered, previous_socket.fingerprints, previous_components)

      assert full_render == %{0 => 0}
      assert socket.fingerprints == previous_socket.fingerprints
      assert components == previous_components

      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :component}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      assert_received {:update, %{from: :component}, %Socket{assigns: %{hello: "world"}}}
      refute_received _
    end

    test "on update with render" do
      component = %Component{id: "hello", assigns: %{from: :component}, component: MyComponent}
      rendered = component_template(%{component: component})
      {previous_socket, _, previous_components} = render(rendered)

      component = %Component{id: "hello", assigns: %{from: :rerender}, component: MyComponent}
      rendered = component_template(%{component: component})

      {socket, full_render, components} =
        render(rendered, previous_socket.fingerprints, previous_components)

      assert full_render == %{0 => 0, :components => %{0 => %{0 => "rerender"}}}
      assert socket.fingerprints == previous_socket.fingerprints
      assert components != previous_components

      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :component}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      assert_received {:update, %{from: :rerender}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      refute_received _
    end

    test "on addition" do
      component = %Component{id: "hello", assigns: %{from: :component}, component: MyComponent}
      rendered = component_template(%{component: component})
      {previous_socket, _, previous_components} = render(rendered)

      component = %Component{id: "another", assigns: %{from: :another}, component: MyComponent}
      rendered = component_template(%{component: component})

      {socket, full_render, components} =
        render(rendered, previous_socket.fingerprints, previous_components)

      assert full_render == %{
               0 => 1,
               :components => %{
                 1 => %{0 => "another", 1 => "world", :static => ["FROM ", " ", "\n"]}
               }
             }

      assert socket.fingerprints == previous_socket.fingerprints
      assert components != previous_components

      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :component}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :another}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      refute_received _
    end

    test "on replace" do
      component = %Component{id: "hello", assigns: %{from: :component}, component: SameComponent}
      rendered = component_template(%{component: component})
      {previous_socket, _, previous_components} = render(rendered)

      component = %Component{id: "hello", assigns: %{from: :replaced}, component: MyComponent}
      rendered = component_template(%{component: component})

      {socket, full_render, components} =
        render(rendered, previous_socket.fingerprints, previous_components)

      assert full_render == %{
               0 => 0,
               :components => %{
                 0 => %{0 => "replaced", 1 => "world", :static => ["FROM ", " ", "\n"]}
               }
             }

      assert socket.fingerprints == previous_socket.fingerprints
      assert components != previous_components

      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :component}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      assert_received {:mount, %Socket{endpoint: __MODULE__}}
      assert_received {:update, %{from: :replaced}, %Socket{assigns: %{hello: "world"}}}
      assert_received :render
      refute_received _
    end
  end
end
