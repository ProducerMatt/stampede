defmodule Stampede.Interact do
  require Logger
  alias Stampede, as: S
  alias S.Tables.{Ids, Interactions, ChannelLocks}
  import S.Tables, only: [transaction!: 1]
  use TypeCheck
  use TypeCheck.Defstruct

  @type! id :: non_neg_integer()

  @msg_id_timeout 1000

  @spec! get(S.msg_id()) :: {:ok, %Interactions{}} | {:error, any()}
  def get(msg_id_unsafe) do
    msg_id =
      case msg_id_unsafe do
        tup when is_tuple(tup) ->
          # BUG: :mnesia needs literal tuples to be wrapped in order to match correctly
          {tup}

        not_tup ->
          not_tup
      end

    transaction!(fn ->
      Memento.Query.select(
        Interactions,
        {:==, :posted_msg_id, msg_id}
      )
      |> case do
        [result] ->
          {:ok, result}

        [] ->
          {:error, :not_found}

        results when is_list(results) ->
          raise "multiple entries found for one posted_msg_id"
      end
    end)
  end

  @spec! get_traceback(S.msg_id()) :: {:ok, S.traceback()} | {:error, any()}
  def get_traceback(msg_id) do
    transaction!(fn ->
      get(msg_id)
      |> case do
        {:ok, record} ->
          {:ok, record.traceback}

        other ->
          other
      end
    end)
  end

  @spec! channel_locked?(S.channel_id()) :: S.channel_lock_status()
  def channel_locked?(channel_id) do
    match =
      transaction!(fn ->
        Memento.Query.read(ChannelLocks, channel_id)
      end)

    case match do
      %ChannelLocks{lock_status: status, callback: mfa, interaction_id: iid} ->
        if status do
          # get plugin
          plug =
            transaction!(fn ->
              [%{plugin: plug}] =
                Memento.Query.match(Interactions, {iid, :_, :"$1", :_, :_, :_, :_, :_})

              plug
            end)

          {mfa, plug, iid}
        else
          false
        end

      nil ->
        false
    end
  end

  @spec! prepare_interaction!(%S.InteractionForm{}) :: {:ok, S.interaction_id()}
  def prepare_interaction!(int) when is_struct(int, S.InteractionForm) do
    iid = Ids.reserve_id(Interactions)

    new_row =
      struct!(
        Interactions,
        id: iid,
        datetime: S.time(),
        plugin: int.plugin,
        # NOTE: message hasn't been posted yet, get this info back
        posted_msg_id: nil,
        msg: int.msg,
        response: int.response,
        traceback: int.traceback,
        channel_lock: int.channel_lock
      )
      |> Interactions.validate!()

    # IO.puts("Interact: new interaction:\n#{new_row |> S.pp()}") # DEBUG

    :ok =
      transaction!(fn ->
        :ok = do_write_interaction!(new_row)
        :ok = do_channel_lock!(int, new_row.datetime, iid)
      end)

    :ok = announce_interaction(new_row)

    spawn_link(__MODULE__, :check_for_orphaned_interaction, [iid, int.service])

    {:ok, iid}
  end

  @spec! check_for_orphaned_interaction(S.interaction_id(), atom()) :: :ok
  def check_for_orphaned_interaction(id, service) do
    Process.sleep(@msg_id_timeout)

    transaction!(fn ->
      Memento.Query.read(Interactions, id)
      |> Map.fetch!(:posted_msg_id)
      |> case do
        nil ->
          Logger.error(
            fn ->
              [
                "Orphaned interaction ",
                inspect(id),
                " from service ",
                inspect(service),
                " never recorded its posted_msg_id. (timeout ",
                @msg_id_timeout |> to_string(),
                ")"
              ]
            end,
            stampede_component: service,
            interaction_id: id
          )

          :ok

        _ ->
          :ok
      end
    end)
  end

  @spec! finalize_interaction(S.interaction_id(), S.msg_id()) :: :ok
  def finalize_interaction(int_id, posted_msg_id) do
    transaction!(fn ->
      Memento.Query.read(
        Interactions,
        int_id
      )
      |> case do
        nil ->
          raise "Interaction #{inspect(int_id)} not found for message #{inspect(posted_msg_id)}"

        int ->
          _ =
            Map.update!(int, :posted_msg_id, fn
              nil ->
                posted_msg_id

              _already_set ->
                raise "Interaction has posted_msg_id already set.\nNew message ID: #{posted_msg_id |> inspect()}\nInteraction: #{int |> S.pp()}"
            end)
            |> Memento.Query.write()

          :ok
      end
    end)
  end

  @spec! announce_interaction(%Interactions{}) :: :ok
  def announce_interaction(rec) do
    Logger.info(fn ->
      to_print = [
        server: rec.msg.server_id,
        responding_to: rec.msg.author_id,
        responding_plug: rec.response.origin_plug,
        response: rec.response.text,
        channel_lock:
          if rec.channel_lock do
            rec.channel_lock |> inspect()
          else
            false
          end
      ]

      [
        "NEW INTERACTION ",
        inspect(rec.id),
        "\n",
        to_print |> S.pp()
      ]
    end)
  end

  @spec! do_channel_lock!(%S.InteractionForm{}, String.t(), integer()) :: :ok
  def do_channel_lock!(int, datetime, int_id) do
    result =
      transaction!(fn ->
        case int.channel_lock do
          {:lock, channel_id, mfa} ->
            # try writing new channel lock
            case channel_locked?(channel_id) do
              false ->
                new_row =
                  struct!(
                    ChannelLocks,
                    channel_id: channel_id,
                    datetime: datetime,
                    lock_status: true,
                    callback: mfa,
                    interaction_id: int_id
                  )

                :ok = do_write_channellock!(new_row)

              # try to update existing channel lock
              {_mfa, plug, _iid} when is_atom(plug) ->
                if plug != int.response.origin_plug do
                  raise(
                    "plugin #{int.plugin} trying to lock an already-locked channel owned by #{plug}"
                  )
                end

                new_row =
                  struct!(
                    ChannelLocks,
                    channel_id: channel_id,
                    datetime: datetime,
                    lock_status: true,
                    callback: mfa,
                    interaction_id: int_id
                  )

                :ok = do_write_channellock!(new_row)
            end

          {:unlock, channel_id} ->
            # try writing channel lock
            case channel_locked?(channel_id) do
              false ->
                Logger.error("plugin #{int.plugin} trying to unlock an already-unlocked channel")
                :ok

              {_, plug, _} when plug == int.plugin ->
                new_row =
                  struct!(
                    ChannelLocks,
                    channel_id: channel_id,
                    datetime: datetime,
                    lock_status: false,
                    callback: nil,
                    interaction_id: int_id
                  )

                :ok = do_write_channellock!(new_row)

              plug when plug != int.plugin ->
                raise "plugin #{int.plugin |> inspect()} trying to take a lock from #{plug |> inspect()}"

              other ->
                raise "Interact: already existing channel_locked is malformed: #{other |> S.pp()}"
            end

          false ->
            # noop
            :ok

          other ->
            raise "Interact: bad lock: #{other |> S.pp()}"
        end
      end)

    result
  end

  @spec! do_write_channellock!(%ChannelLocks{}) :: :ok
  defp do_write_channellock!(record) do
    _ = ChannelLocks.validate!(record)

    transaction!(fn ->
      _ = Memento.Query.write(record)
    end)

    :ok
  end

  @spec! do_write_interaction!(%Interactions{}) :: :ok
  defp do_write_interaction!(record) do
    transaction!(fn ->
      if id_exists?(record.id), do: raise("Interaction already recorded??")
      _ = Memento.Query.write(record)

      :ok
    end)
  end

  @spec! id_exists?(S.interaction_id()) :: boolean()
  def id_exists?(id) do
    transaction!(fn ->
      Memento.Query.read(Interactions, id) != nil
    end)
  end
end
