defmodule Support.Async do
  @moduledoc false
  # Helper for creating asynchronous tests
  # Doesn't support calling private functions (yet)

  defmacro async_test(
             name,
             context \\ quote do
               %{}
             end,
             do: block
           ) do
    id = :crypto.strong_rand_bytes(12) |> Base.encode16()
    module_name = Module.concat(["AsyncTest_#{id}"])

    %Macro.Env{
      aliases: aliases,
      requires: requires,
      functions: functions,
      macros: macros,
      module: caller
    } =
      __CALLER__

    imports =
      (macros ++ functions)
      |> Enum.group_by(&Bunch.key/1, &Bunch.value/1)
      |> Enum.map(fn {module, imports} ->
        quote do
          import unquote(module), only: unquote(List.flatten(imports))
        end
      end)

    requires =
      Enum.map(
        requires,
        &quote do
          require unquote(&1)
        end
      )

    aliases =
      Enum.map(
        aliases,
        fn {aliased, module} ->
          quote do
            alias unquote(module), as: unquote(aliased)
          end
        end
      )

    quote do
      defmodule unquote(module_name) do
        use ExUnit.Case, async: true
        unquote_splicing(imports)
        unquote_splicing(requires)
        unquote_splicing(aliases)

        tags_attrs =
          [:tag, :describetag, :moduletag]
          |> Enum.flat_map(fn attr ->
            Module.get_attribute(unquote(caller), attr)
            |> Enum.map(&{attr, &1})
          end)

        Module.attributes_in(unquote(caller))
        |> Enum.reject(
          &(&1 in (Map.keys(Module.reserved_attributes()) ++ Module.attributes_in(__MODULE__)))
        )
        |> Enum.map(&{&1, Module.get_attribute(unquote(caller), &1)})
        |> Enum.concat(tags_attrs)
        |> Enum.each(fn {name, value} -> Module.put_attribute(__MODULE__, name, value) end)

        test unquote(name), unquote(context) do
          unquote(block)
        end
      end

      Module.delete_attribute(__MODULE__, :tag)
    end
  end
end
