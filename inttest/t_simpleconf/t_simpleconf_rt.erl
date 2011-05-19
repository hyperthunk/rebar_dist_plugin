-module(t_simpleconf_rt).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(EXPECTED_OUTPUT,
    "custom-assembly/target/priv/bin/custom-app").

files() ->
    [{copy,
        "../../examples/custom-assembly", "custom-assembly"},
     {copy, "rebar.config", "custom-assembly/rebar.config"}].

run(_Dir) ->
    ?assertMatch({ok, _}, retest:sh("rebar get-deps check-deps compile -v",
                                    [{dir, "custom-assembly"}])),
    ?assertMatch({ok, _}, retest:sh("rebar escriptize dist -v",
                                    [{dir, "custom-assembly"}])),
    ?assertMatch({ok, _}, retest:sh("tar -zxf custom_app.tar.gz",
                                    [{dir, "custom-assembly/target"}])),
    ?assert(filelib:is_regular(?EXPECTED_OUTPUT)),
    ?assertMatch({ok, _}, retest:sh("rebar distclean -v",
                                    [{dir, "custom-assembly"}])),
    ?assert(filelib:is_dir("custom-assembly/target") == false),
    ok.
