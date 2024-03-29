defmodule StampedeStatelessTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Stampede, as: S
  require S.Msg
  doctest Stampede

  @dummy_cfg """
    service: dummy
    server_id: testing
    error_channel_id: error
    prefix: "!"
    dm_handler: true
    plugs:
      - Test
      - Sentience
  """
  @dummy_cfg_verified %{
    service: Service.Dummy,
    server_id: :testing,
    error_channel_id: :error,
    prefix: "!",
    plugs: MapSet.new([Plugin.Test, Plugin.Sentience]),
    vip_ids: MapSet.new([:server]),
    dm_handler: true
  }

  describe "stateless functions" do
    test "strip_prefix text" do
      assert "ping" == S.strip_prefix("!", "!ping")
    end

    test "strip_prefix regex" do
      assert "ping" == S.strip_prefix(~r/(.*) me bro/, "ping me bro")
    end

    test "S.keyword_put_new_if_not_falsy" do
      kw1 = [a: 1, b: 2]
      kw2 = [a: 1, b: 2, c: 3]

      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:a, false)
      assert kw1 == kw1 |> S.keyword_put_new_if_not_falsy(:b, 4)
      assert kw2 == kw1 |> S.keyword_put_new_if_not_falsy(:c, 3) |> Enum.sort()
    end

    test "basic test plugin" do
      msg =
        S.Msg.new(
          id: 0,
          body: "!ping",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      dummy_cfg = %{
        __struct__: SiteConfig,
        service: Service.Dummy,
        prefix: "!"
      }

      r = Plugin.Test.process_msg(dummy_cfg, msg)
      assert r.text == "pong!"

      msg =
        S.Msg.new(
          id: 0,
          body: "!raise",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      assert_raise SillyError, fn -> Plugin.Test.process_msg(dummy_cfg, msg) end

      msg =
        S.Msg.new(
          id: 0,
          body: "!throw",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      try do
        Plugin.Test.process_msg(dummy_cfg, msg)
      catch
        _t, e ->
          assert e == SillyThrow
      end

      msg =
        S.Msg.new(
          id: 0,
          body: "!callback",
          channel_id: :t1,
          author_id: :u1,
          server_id: :none
        )

      %{callback: {m, f, a}} = Plugin.Test.process_msg(dummy_cfg, msg)

      cbr = apply(m, f, [dummy_cfg | a])
      assert String.starts_with?(cbr.text, "Called back with")
    end

    test "SiteConfig load" do
      verified = SiteConfig.load_from_string(@dummy_cfg)
      assert verified == @dummy_cfg_verified
    end

    test "SiteConfig dm handler" do
      cfg = @dummy_cfg_verified

      svmap =
        %{cfg.service => %{cfg.server_id => cfg}}
        |> SiteConfig.make_configs_for_dm_handling()

      #  |> IO.inspect(pretty: true) # Debug

      key = S.make_dm_tuple(cfg.service)

      assert key ==
               Map.fetch!(svmap, cfg.service)
               |> Map.fetch!(S.make_dm_tuple(cfg.service))
               |> Map.fetch!(:server_id)
    end

    test "vip check" do
      vips = %{some_server: MapSet.new([:admin])}

      assert S.vip_in_this_context?(
               vips,
               :some_server,
               :admin
             )

      assert S.vip_in_this_context?(
               vips,
               :all,
               :admin
             )

      assert false ==
               S.vip_in_this_context?(
                 vips,
                 :some_server,
                 :non_admin
               )
    end

    test "msg splitting functions" do
      split_size = 100
      max_pieces = 10

      correctly_split_msg =
        1..max_pieces
        |> Enum.map(fn _ -> S.random_string_weak(split_size) end)

      large_msg = Enum.join(correctly_split_msg) <> S.random_string_weak(div(split_size, 5))

      smol_msg = "lol"

      assert correctly_split_msg == S.text_chunk(large_msg, split_size, max_pieces)
      assert [smol_msg] == S.text_chunk(smol_msg, split_size, max_pieces)
    end
  end

  describe "cfg_table" do
    test "do_vips_configured" do
      result =
        %{
          Service.Dummy => %{
            foo: %{
              server_id: :foo,
              vip_ids: MapSet.new([:bar, :baz])
            }
          }
        }
        |> S.CfgTable.do_vips_configured(Service.Dummy)

      assert result == %{foo: MapSet.new([:bar, :baz])}
    end
  end

  describe "text formatting" do
    test "flattens lists" do
      input = [[[], []], [["f"], ["o", "o"]], ["b", ["a"], "r"]]
      wanted = ["f", "o", "o", "b", "a", "r"]

      assert wanted == TxtBlock.to_str_list(input, Service.Dummy)
      assert "lol" == TxtBlock.to_str_list([[[[[], [[[["lol"], []]]]]]]], Service.Dummy)
    end

    test "source block" do
      correct =
        """
        ```
        foo
        ```
        """

      one =
        TxtBlock.to_binary(
          {:source_block, "foo\n"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:source_block, [["f"], [], "o", [["o"], "\n"]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "source ticks" do
      correct = "`foo`"

      one =
        TxtBlock.to_binary(
          {:source, "foo"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:source, [["f"], [], "o", [["o"]]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "quote block" do
      correct = "> foo\n> bar\n"

      one =
        TxtBlock.to_binary(
          {:quote_block, "foo\nbar"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {:quote_block, [["f"], [], "o", [["o"]], ["\n", "bar"]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "indent block" do
      correct = "  foo\n  bar\n"

      one =
        TxtBlock.to_binary(
          {{:indent, "  "}, "foo\nbar"},
          Service.Dummy
        )

      two =
        TxtBlock.to_binary(
          {{:indent, 2}, [["f"], [], "o", [["o"]], ["\n", "bar"]]},
          Service.Dummy
        )

      assert one == correct
      assert two == correct
    end

    test "Markdown" do
      processed =
        TxtBlock.Debugging.all_formats_example()
        |> TxtBlock.to_binary(Service.Dummy)

      assert processed == TxtBlock.Md.Debugging.all_formats_processed()
    end
  end
end
