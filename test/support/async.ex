defmodule Support.Async do
  @moduledoc false
  # Helper for creating asynchronous tests
  # - creates a public function instead of a test
  # - creates a module with a single test that calls said function
  # - copies all @tags to the newly created module
  # - use async_setup instead of setup
  # - setup_all is not supported

  defmacro async_test(
             test_name,
             context \\ quote do
               %{}
             end,
             do: block
           ) do
    quote do
      id = :erlang.unique_integer([:positive])
      test_module_name = Module.concat(__MODULE__, "AsyncTest_#{id}")
      fun_name = :"async_test_#{id}"
      after_compile_fun_name = :"async_test_ac_#{id}"

      @tags_attrs [:tag, :describetag, :moduletag]
                  |> Enum.flat_map(fn attr ->
                    Module.get_attribute(__MODULE__, attr)
                    |> Enum.map(&{attr, &1})
                  end)

      @setups Module.get_attribute(__MODULE__, :async_setup, [])
      @setup_alls Module.get_attribute(__MODULE__, :async_setup_all, [])

      def unquote(unquoted_var(:fun_name))(unquote(context)) do
        unquote(block)
      end

      def unquote(unquoted_var(:after_compile_fun_name))(_bytecode, _env) do
        test_name = unquote(unquoted(test_name))
        fun_name = unquote(unquoted_var(:fun_name))

        content =
          quote do
            use ExUnit.Case, async: true

            Enum.each(unquote(@tags_attrs), fn {name, value} ->
              Module.put_attribute(__MODULE__, name, value)
            end)

            for setup_all_name <- unquote(@setup_alls) do
              setup_all {unquote(__MODULE__), setup_all_name}
            end

            for setup_name <- unquote(@setups) do
              setup {unquote(__MODULE__), setup_name}
            end

            test unquote(test_name), context do
              unquote(__MODULE__).unquote(fun_name)(context)
            end
          end

        Module.create(unquote(unquoted_var(:test_module_name)), content, __ENV__)
      end

      @after_compile {__MODULE__, after_compile_fun_name}

      Module.delete_attribute(__MODULE__, :tag)
    end
  end

  defmacro async_setup(context, do: block) do
    do_setup(context, block)
  end

  defmacro async_setup(block) do
    do_setup(quote(do: %{}), block)
  end

  def do_setup(context, block) do
    name = :"async_setup_#{:erlang.unique_integer([:positive])}"

    quote bind_quoted: [context: escape(context), block: escape(block), name: name] do
      prev_setup = Module.get_attribute(__MODULE__, :async_setup, [])
      def unquote(name)(unquote(context)), unquote(block)
      Module.put_attribute(__MODULE__, :async_setup, [name | prev_setup])
    end
  end

  defp escape(contents) do
    Macro.escape(contents, unquote: true)
  end

  defp unquoted_var(name) do
    unquoted(Macro.var(name, __MODULE__))
  end

  defp unquoted(ast) do
    {:unquote, [], [ast]}
  end
end
