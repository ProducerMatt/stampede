defmodule SiteConfig do
  @moduledoc """
  This module defines how per-site configurations are validated and represented.

  A configuration usually starts as a YAML file on-disk. It is then:
  - read into an Erlang term
  - validated with NimbleOptions (simultaneously handling defaults and type-checking)
  - some transformations are done; for example, turning atoms referring to services and plugins into their proper names ("discord" into Elixir.Service.Discord, "why" into Elixir.Plugin.Why).
  - turned into a SiteConfig struct (internally a map)
  - Given to Stampede.CfgTable which handles storage of the configs and keeping services up-to-date.

  schema_base() defines a basic site config schema, which is extended by Services for their needs.
  """
  use TypeCheck
  use TypeCheck.Defstruct
  alias Stampede, as: S
  require S

  @yaml_opts [:plain_as_atom]

  @type! service :: atom()
  @type! server_id :: S.server_id()
  @type! channel_id :: S.channel_id()
  @type! schema :: keyword() | struct()
  @type! site_name :: atom()
  @typedoc "A nested collection of configs, organized by service, then server_id"
  @type! cfg_list :: map(service(), map(server_id(), SiteConfig.t()))
  @type! t :: map(atom(), any())

  @schema_base [
    service: [
      required: true,
      type: :atom,
      doc:
        "Which service does your server reside on? Affects what config options are valid. A basic atom which becomes the module name, i.e. :discord -> Service.Discord"
    ],
    server_id: [
      required: true,
      type: :any,
      doc: "Discord Guild ID, Slack group, etc. Name 'DM' for direct message handling"
    ],
    vip_ids: [
      default: MapSet.new(),
      type: :any,
      doc: "User IDs, who are trusted to not abuse the bot"
    ],
    error_channel_id: [
      required: true,
      type: :any,
      doc:
        "What channel should debugging messages be posted on? Messages may have private information."
    ],
    prefix: [
      default: "!",
      type: S.ntc(Regex.t() | String.t()),
      doc: "What prefix should users put on messages to have them responded to?"
    ],
    plugs: [
      default: :all,
      type: {:custom, __MODULE__, :real_plugins, []},
      doc: "Which plugins will be asked for responses."
    ],
    dm_handler: [
      default: false,
      type: :boolean,
      doc: "Use this config for DMs received on this service. Only one config per service"
    ]
  ]
  @mapset_keys [:vip_ids]
  @doc """
  A basic Cfg schema, to be extended by the specific service it's written for.

  #{NimbleOptions.docs(NimbleOptions.new!(@schema_base))}
  """
  def schema_base(), do: @schema_base

  def merge_custom_schema(overrides, base_schema \\ schema_base()) do
    Keyword.merge(base_schema, overrides, fn
      _key, base_settings, new_settings ->
        case Keyword.get(base_settings, :doc, false) do
          false -> new_settings
          doc -> Keyword.put_new(new_settings, :doc, doc)
        end
    end)
  end

  def schema(atom),
    do: S.service_atom_to_name(atom) |> apply(:site_config_schema, [])

  def fetch!(cfg, key) when is_map_key(cfg, key), do: Map.fetch!(cfg, key)

  @doc "Verify that explicitly listed plugins actually exist"
  def real_plugins(:all), do: {:ok, :all}
  def real_plugins(:none), do: {:ok, :none}

  def real_plugins(plugs) when not is_struct(plugs, MapSet),
    do: raise("This is not a mapset: #{inspect(plugs)}")

  def real_plugins(plugs) when is_struct(plugs, MapSet) do
    existing = Plugin.ls(plugs)

    if MapSet.equal?(existing, plugs) do
      {:ok, plugs}
    else
      raise "Some plugins not found.\nFound: #{inspect(existing)}\nConfigured: #{inspect(plugs)}"
    end
  end

  @doc "take input config as keywords, transform as necessary, validate, and return as map"
  @spec! validate!(
           kwlist :: keyword(),
           schema :: nil | schema(),
           additional_transforms :: [] | list((keyword(), schema() -> keyword()))
         ) ::
           SiteConfig.t()
  def validate!(kwlist, schema \\ nil, additional_transforms \\ []) do
    schema = schema || Keyword.fetch!(kwlist, :service) |> schema()

    transforms = [
      &concat_plugs/2,
      &make_regex/2,
      make_mapsets(@mapset_keys),
      fn kwlist, _ ->
        Keyword.update!(kwlist, :service, &S.service_atom_to_name(&1))
      end
    ]

    Enum.reduce(transforms ++ additional_transforms, kwlist, fn f, acc ->
      f.(acc, schema)
    end)
    |> NimbleOptions.validate!(schema)
    |> Map.new()
  end

  @spec! revalidate!(kwlist :: keyword() | map(), schema :: nil | schema()) :: SiteConfig.t()
  def revalidate!(cfg, schema) do
    cfg
    |> then(fn
      l when is_list(l) -> l
      m when is_map(m) -> Map.to_list(m)
    end)
    |> NimbleOptions.validate!(schema)
    |> Map.new()
  end

  @doc "Turn plug_name into Elixir.Plugin.PlugName"
  def concat_plugs(kwlist, _schema) do
    if is_list(Keyword.get(kwlist, :plugs)) do
      Keyword.update!(kwlist, :plugs, fn plugs ->
        case plugs do
          :all ->
            :all

          ll when is_list(ll) ->
            Enum.map(ll, fn name ->
              camel_name = name |> to_string() |> Macro.camelize()
              Module.safe_concat(Plugin, camel_name)
            end)
            |> MapSet.new()
        end
      end)
    else
      kwlist
    end
  end

  @doc "If prefix describes a Regex, compile it"
  def make_regex(kwlist, _schema) do
    if Keyword.has_key?(kwlist, :prefix) do
      Keyword.update!(kwlist, :prefix, fn prefix ->
        if String.starts_with?(prefix, "~r") do
          Regex.compile!(prefix)
        else
          prefix
        end
      end)
    else
      kwlist
    end
  end

  @doc "For the given keys, make a function that will replace the enumerables at those keys with MapSets"
  @spec! make_mapsets(list(atom())) :: (keyword(), any() -> keyword())
  def make_mapsets(keys) do
    fn kwlist, _schema ->
      Enum.reduce(keys, kwlist, fn key, acc ->
        case Keyword.get(acc, key, false) do
          false ->
            acc

          enum when is_list(enum) or enum == [] ->
            Keyword.update!(acc, key, fn enum -> MapSet.new(enum) end)
        end
      end)
    end
  end

  @spec! load_from_string(String.t()) :: SiteConfig.t()
  def load_from_string(yml) do
    case :fast_yaml.decode(yml, @yaml_opts) do
      {:error, reason} ->
        raise("bad yaml from string\n#{reason}")

      {:ok, [result]} ->
        validate!(result)
    end
  end

  @spec! load(String.t()) :: SiteConfig.t()
  def load(path) do
    File.read!(path)
    |> load_from_string()
  end

  @doc "Load all YML files in a directory and return a map of configs"
  @spec! load_all(String.t()) :: cfg_list()
  def load_all(dir) do
    target_dir = dir
    # IO.puts("target dir " <> dir) # DEBUG

    Path.wildcard(target_dir <> "/*")
    |> Enum.reduce(Map.new(), fn path, service_map ->
      site_name = String.to_atom(Path.basename(path, ".yml"))
      # IO.puts("add #{site_name} at #{path} to #{S.pp(service_map)}") # DEBUG
      config =
        load(path)
        |> Map.put(:filename, site_name)

      service = Map.fetch!(config, :service)
      server_id = Map.fetch!(config, :server_id)

      service_map
      |> Map.put_new(service, Map.new())
      |> Map.update!(service, fn
        server_map ->
          # IO.puts("add server #{server_id} to service #{service}") # DEBUG
          Map.put(server_map, server_id, config)
      end)
      |> make_configs_for_dm_handling()
    end)

    # Did you know that "default" in Map.update/4 isn't an input to the
    # function? It just skips the function and adds that default to the map.
    # I didn't know that. Now I do. :')
  end

  @spec! make_configs_for_dm_handling(cfg_list()) :: cfg_list()
  @doc """
  Create a config with key {:dm, service} which all DMs for a service will be handled under.
  If server_id is not "DM", it will be duplicated with one for the server and
  one for the DMs.
  Collects all VIPs for that service and puts them in the DM config.
  """
  def make_configs_for_dm_handling(service_map) do
    Map.new(service_map, fn {service, site_map} ->
      dupe_checked =
        Enum.reduce(
          site_map,
          {Map.new(), MapSet.new(), MapSet.new()},
          # Accumulator keeps a map for the sites being processed, and a mapset to check for duplicate keys
          fn {server_id, orig_cfg}, {site_acc, services_handled, service_vips} ->
            if not orig_cfg.dm_handler do
              {
                Map.put(site_acc, server_id, orig_cfg),
                services_handled,
                if vips = Map.get(orig_cfg, :vip_ids, false) do
                  MapSet.union(service_vips, vips)
                else
                  service_vips
                end
              }
            else
              if orig_cfg.service in services_handled do
                raise "duplicate dm_handler for service #{orig_cfg.service |> inspect()}"
              end

              dm_key = S.make_dm_tuple(orig_cfg.service)
              dm_cfg = Map.put(orig_cfg, :server_id, dm_key)

              # config is for DM handling exclusively
              new_site_acc =
                if server_id != "DM" do
                  Map.put(site_acc, server_id, orig_cfg)
                else
                  site_acc
                end
                |> Map.put(dm_key, dm_cfg)

              {
                new_site_acc,
                services_handled |> MapSet.put(orig_cfg.service),
                if vips = Map.get(orig_cfg, :vip_ids, false) do
                  MapSet.union(service_vips, vips)
                else
                  service_vips
                end
              }
            end
          end
        )
        |> elem(0)

      {service, dupe_checked}
    end)
  end
end
