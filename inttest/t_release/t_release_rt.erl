-module(t_release_rt).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

files() ->
    [{copy,
        "../../examples/release-tarball/rel", "release-tarball/rel"},
     {copy,
        "../../examples/release-tarball/src", "release-tarball/src"},
     {copy,
        "../../examples/release-tarball/myvars.vars", "release-tarball/myvars.vars"},
     {copy,
        "../../examples/release-tarball/rebar.config", "release-tarball/rebar.config"},
     {copy, "rebar.config", "release-tarball/rebar.config"}].

run(_Dir) ->
    ?assertMatch({ok, _}, retest:sh("rebar get-deps compile-deps -v && "
                                    "rm -dr deps/rebar_dist_plugin/examples",
                                 [{dir, "release-tarball"}])),
    ?assertMatch({ok, _}, retest:sh("rebar cl comp generate dist -v",
                                 [{dir, "release-tarball"}])),
    ?assertMatch({ok, _}, retest:sh("tar -zxf foo-1.2.3.tar.gz",
                                 [{dir, "release-tarball/dist"}])),

    ?assert(exists("exemplar/bin/exemplar")),
    ?assert(exists("exemplar/etc/app.config")),
    ?assert(exists("exemplar/releases/1/exemplar.rel")),
    ?assertMatch({ok, _}, retest:sh("rebar distclean -v",
                                 [{dir, "release-tarball"}])),
    ?assert(not exists("exemplar")),
    ok.

exists(F) ->
    filelib:is_regular(expected_file(F)).

expected_file(Path) ->
    filename:join("release-tarball/dist", Path).
