%% -----------------------------------------------------------------------------
%%
%% Rebar Dist Plugin
%%
%% Copyright (c) 2011 Tim Watson (watson.timothy@gmail.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -----------------------------------------------------------------------------
%% @author Tim Watson [http://hyperthunk.wordpress.com]
%% @copyright (c) Tim Watson, 2011
%% @since: April 2011
%%
%% @doc Rebar Dist Plugin.
%%
%% This plugin allows you to package up a (configurable) set of files into a
%% compressed archive (i.e. .tar.gz or .zip). The plugin's rebar configuration
%% supports wildcards in both relative and absolute paths for files and
%% directories, output path/file name and will allow you to make multiple files
%% if so required.
%%
%% The plugin exports a new `dist` command, an will also run in response to the
%% `generate` and `clean` commands, if configured to do so.
%% -----------------------------------------------------------------------------
-module(rebar_dist_plugin).

-include_lib("kernel/include/file.hrl").
-compile(export_all).

-export([dist/2, distclean/2]).
-export([post_generate/2, post_clean/2]).

-compile(export_all).

-define(DEBUG(Msg, Args),
    rebar_log:log(debug, "[~p] " ++ Msg, [?MODULE|Args])).

-define(WARN(Msg, Args),
    rebar_log:log(warn, "[~p] " ++ Msg, [?MODULE|Args])).

-record(assembly, {name, opts}).
-record(conf, {base, rebar, dist}).
-record(spec, {path, glob, target, mode, template}).
-record(entry, {spec, source, target, data, info}).

%%
%% Public API
%%

dist(Config, AppFile) ->
    run(fun() ->
        {App, DistConfig} = scope_config(AppFile, Config),
        dist(#conf{ base=App, rebar=Config, dist=DistConfig })
    end).

distclean(Config, AppFile) ->
    run(fun() ->
        {_, DistConfig} = scope_config(AppFile, Config),
        Outdir = outdir(DistConfig),
        rebar_file_utils:rm_rf(Outdir)
    end).

%% TODO: switch these to run post_generate and post_clean

post_generate(Config, RelFile) ->
    DistConfig = rebar_config:get(Config, dist, []),
    Attach = proplists:get_value(attach, DistConfig, []),
    case lists:member(generate, Attach) of
        true ->
            rebar_log:log(debug,
                "Running Dist Plugin `generate' Hook ~p~n", [Config]),
            dist(Config, RelFile);
        false ->
            ok
    end.

post_clean(Config, AppFile) ->
    DistConfig = rebar_config:get(Config, dist, []),
    Attach = proplists:get_value(attach, DistConfig, []),
    case lists:member(clean, Attach) of
        true ->
            rebar_log:log(debug,
                "Running Dist Plugin `clean' Hook ~p~n", [Config]),
            distclean(Config, AppFile);
        false ->
            ok
    end.

%%
%% (Public) Utility functions used in read_conf as bindings
%%

glob(Expr) ->
    #spec{glob=Expr}.

template({glob, Glob}) ->
    #spec{glob=Glob, template=true};
template(Path) ->
    #spec{path=Path, template=true}.

template({glob, Glob}, Target) ->
    #spec{glob=Glob, target=Target, template=true};
template(Path, Target) ->
    #spec{path=Path, target=Target, template=true}.

spec({glob, Glob}, Target) ->
    #spec{glob=Glob, target=Target};
spec(Path, Target) ->
    #spec{path=Path, target=Target}.

name(Target) ->
    {name, Target}.

is_rel_dir(Dir) ->
    case get(reldir) of
        undefined ->
            ?DEBUG("Unable to check ~p as reldir is undefined~n", [Dir]),
            false;
        Path ->
            [$/|Other] = lists:reverse(Path),
            RelDir = lists:reverse(Other),
            lists:prefix(RelDir, Dir)
    end.

reldir() ->
    get(reldir).

relvsn() ->
    Dir = reldir(),
    ?DEBUG("Checking for reltool.config in ~p~n", [Dir]),
    case catch(release_vsn(Dir)) of
        {_Name, Ver} ->
            ?DEBUG("Found version ~p~n", [Ver]),
            Ver;
        Other ->
            ?WARN("Bad release_vsn? ~p~n", [Other]),
            undefined
    end.

basedir() ->
    get(basedir).

basename() ->
    basename(reldir()).

basename(undefined) ->
    ?WARN("No release_dir? ~n", []),
    filename:basename(rebar_utils:get_cwd());
basename(RelDir) ->
    case release_vsn(RelDir) of
        {Name, _Ver} ->
            Name;
        Other ->
            ?WARN("Bad release_vsn? ~p~n", [Other]),
            basename(undefined)
    end.

appname() ->
    get(appname).

appvsn() ->
    get(appvsn).

fnmatch(Fun) when is_function(Fun, 1) ->
    #spec{glob={fnmatch, Fun}}.

fnmatch(Fun, Target) when is_function(Fun, 1) ->
    #spec{glob={fnmatch, Fun}, target=Target}.

%%
%% Internal API
%%

run(Func) ->
    case rebar_rel_utils:is_rel_dir() of
        {true, _} ->
            put(reldir, rebar_utils:get_cwd() ++ "/"),
            %%Func();
            ok;
        _ ->
            BaseDir = rebar_config:get_global(base_dir, []),
            Cwd = rebar_utils:get_cwd(),
            case is_subdir(BaseDir, Cwd) of
                false ->
                    put(basedir, Cwd ++ "/"),
                    ?DEBUG("Checking for app file(s)...~n", []),
                    case rebar_app_utils:is_app_dir(rebar_utils:get_cwd()) of
                        {true, AppFile} ->
                            ?DEBUG("Found ~p~n", [AppFile]),
                            store_app_details(AppFile);
                        _ -> 
                            ok
                    end,
                    Func();
                true ->
                    %% skip subdirs apart from the *release* directory
                    ok 
            end
    end.

is_subdir(Base, Dir) ->
    ?DEBUG("Checking to see if ~s is a subdirectory of ~s~n", [Dir, Base]),
    case lists:prefix(Base, Dir) of
        true ->
            length(filename:split(Dir)) > length(filename:split(Base));
        _ ->
            false
    end.

store_app_details(AppFile) ->
    put(appname, rebar_app_utils:app_name(AppFile)),
    put(appvsn, rebar_app_utils:app_vsn(AppFile)).

dist(Conf) ->
    Results = [ process_assembly(A) || A <- find_assemblies(Conf) ],
    Errors = [R || R <- Results, R =/= ok],
    case (length(Errors) > 0) of
        true ->
            {error, Errors};
        false ->
            ok
    end.

process_assembly(#assembly{name=Name, opts=Opts}) ->
    Format = proplists:get_value(format, Opts, tar),
    Outdir = outdir(Opts),
    InclFiles = proplists:get_value(incl_files, Opts, []),
    InclDirs = proplists:get_value(incl_dirs, Opts, []),
    ExclFiles = collect_files(proplists:get_value(excl_files, Opts, [])),
    ExclDirs = collect_dirs(proplists:get_value(excl_dirs, Opts, [])),
    Excl = lists:concat([ExclDirs, ExclFiles]),
    Files = collect_files(InclFiles),
    CopyFiles = filter(merge_templates(Files, Opts), Excl),
    DirEntryPaths = collect_dirs(InclDirs),
    FilteredPaths = filter(DirEntryPaths, Excl),
    MergedPaths = lists:foldl(fun merge_paths/2, FilteredPaths, CopyFiles),
    Pwd = rebar_utils:get_cwd(),
    MergedFsEntries = [ output_def(S, F, Pwd) || {S, F} <- MergedPaths ],
    write_assembly(Format, Name, Outdir, MergedFsEntries, Opts).

write_assembly(zip, Name, Outdir, MergedFsEntries, Conf) ->
    write_assembly(zip, ".zip", Name, Outdir, MergedFsEntries, Conf);
write_assembly(tar, Name, Outdir, MergedFsEntries, Conf) ->
    write_assembly(tar, ".tar.gz", Name, Outdir, MergedFsEntries, Conf).
    
write_assembly(Handler, Ext, Name, Outdir, MergedFsEntries, Conf) ->
    ensure_path(Outdir),
    Filename = assembly_name(filename:join(Outdir, Name), Ext, Conf),
    Prefix = proplists:get_value(prefix, Conf, Name),
    Entries = [ make_entry(Handler, E, Prefix) || E <- MergedFsEntries ],
    case rebar_config:get_global(dryrun, false) of
        false ->
            apply(?MODULE, Handler, [Filename, Entries]);
        _ ->
            print_assembly(Filename, Entries),
            ok
    end.

tar(Filename, Entries) ->
    ?DEBUG("Create Tarball: ~s~n", [Filename]),
    erl_tar:create(Filename, Entries, [write, compressed]).

zip(Filename, Entries) ->
    ?DEBUG("Create Zip Archive: ~s~n", [Filename]),
    case zip:create(Filename, Entries, []) of
        {ok, _} ->
            ok;
        Other ->
            ?DEBUG("Failed!~n", []),
            print_assembly(Filename, Entries),
            Other
    end.

assembly_name(Path, Ext, Conf) ->
    case proplists:get_value(version, Conf, undefined) of
        undefined ->
            Path ++ Ext;
        {git, tag}=GitTag ->
            Path ++ "-" ++ scm_version(GitTag) ++ Ext;
        {scm, _}=ScmCmd ->
            Path ++ "-" ++ scm_version(ScmCmd) ++ Ext;
        Vsn when is_list(Vsn) ->
            Path ++ "-" ++ Vsn ++ Ext
    end.

release_vsn(undefined) ->
    "";
release_vsn(Dir) ->
    File = filename:join(Dir, "reltool.config"),
    case filelib:is_regular(File) of
        true ->
            rebar_rel_utils:get_reltool_release_info(File);
        _ ->
            ""
    end.

scm_version({git, tag}) ->
    scm_version({scm, "git describe --abbrev=0"});
scm_version({scm, Cmd}) ->
    {ok, Vsn} = rebar_utils:sh(Cmd, []),
    string:strip(Vsn, right, $\n).

print_assembly(Filename, Entries) ->
    io:format("INFO:  [~p] ==> Create-Archive: ~s~n", [?MODULE, Filename]),
    lists:map(fun print_entry/1, Entries).

print_entry(E) when is_list(E) ->
    io:format("INFO:  [~p] ==> Archive-Entry: [Source/Target: ~s]~n",
              [?MODULE, E]);
print_entry({E, Target}) when is_list(Target) andalso E == Target ->
    io:format("INFO:  [~p] ==> Archive-Entry: [Source/Target: ~s, Data: ~s]~n", 
              [?MODULE, E, "N/A"]);
print_entry({E, Target}) when is_list(Target) andalso E /= Target ->
    io:format("INFO:  [~p] ==> Archive-Entry: [Source: ~s, "
            "Target: ~s, Data: N/A]~n", 
            [?MODULE, E, Target]);
print_entry({E, Data}) when is_binary(Data) ->
    Bin = integer_to_list(byte_size(Data)) ++ " bytes", 
    io:format("INFO:  [~p] ==> Archive-Entry: [Source/Target: ~s, Data: ~s]~n", 
              [?MODULE, E, Bin]).

read_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

make_entry(zip, E, Prefix) ->
    zip_entry(E, Prefix);
make_entry(tar, E, Prefix) ->
    tar_entry(E, Prefix).

zip_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=regular}}, Prefix) when Src == Targ ->
    target(Prefix, Src);
zip_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=regular}}, Prefix) when Src /= Targ ->
    {target(Prefix, Targ), read_file(Src)};
zip_entry(#entry{source=Src, target=undefined, data=Bin,
                 info=#file_info{type=regular}}, Prefix) when is_binary(Bin) ->
    {target(Prefix, Src), Bin};
zip_entry(#entry{target=Targ, data=Bin,
                 info=#file_info{type=regular}}, Prefix) when is_binary(Bin) ->
    {target(Prefix, Targ), Bin}.

tar_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=regular}}, Prefix) when Src == Targ ->
    target(Prefix, Src);
tar_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=regular}}, Prefix) when Src /= Targ ->
    {target(Prefix, Targ), Src};
tar_entry(#entry{source=Src, target=undefined, data=Bin,
                 info=#file_info{type=regular}}, Prefix) when is_binary(Bin) ->
    {target(Prefix, Src), Bin};
tar_entry(#entry{target=Targ, data=Bin,
                 info=#file_info{type=regular}}, Prefix) when is_binary(Bin) ->
    {target(Prefix, Targ), Bin}.

target(Prefix, Thing) ->
    filename:join(Prefix, Thing).

output_def(Spec, {File, Data}, Pwd) ->
    output_def(Spec, File, Data, Pwd);
output_def(Spec, File, Pwd) ->
    output_def(Spec, File, undefined, Pwd).

output_target(Entry, Base) ->
    re:replace(Entry, Base ++ "/", "", [{return, list}]).

output_def(Spec, File, Data, Pwd) ->
    %% ?DEBUG("Generating output for ~s~n", [File]),
    {ok, FI} = file:read_file_info(File),
    case Spec#spec.target of
        None when None == undefined orelse None == '_' ->
            NewTarget = output_target(File, Pwd),
            #entry{spec=Spec,
                   source=File,
                   data=Data,
                   target=NewTarget,
                   info=FI};
        {name, Target} ->
            case FI#file_info.type of
                regular ->
                    #entry{spec=Spec, source=File,
                           data=Data, target=Target, info=FI};
                _ ->
                    #entry{spec=Spec,
                           source=File,
                           target=output_target(File, Pwd),
                           info=FI}
            end;
        NameGen when is_function(NameGen) ->
            NewName = NameGen(File),
            output_def(Spec#spec{target={name, NewName}}, File, Data, Pwd);
        Target ->
            ?DEBUG("Target == ~p~n", [Target]),
            case FI#file_info.type of
                regular ->
                    NewName = filename:join(Target, filename:basename(File)),
                    #entry{spec=Spec, source=File,
                           data=Data, target=NewName, info=FI};
                _ ->
                    #entry{spec=Spec,
                           source=File,
                           target=output_target(File, Pwd),
                           info=FI}
            end
    end.


filter(Items, Excl) ->
    Exclusions = [ E || {_, E} <- Excl ],
    lists:filter(fun(I) -> should_include(I, Exclusions) end, Items).

should_include({_, {Incl, _}}, Exclusions) ->
    should_include(Incl, Exclusions);
should_include({_, Incl}, Exclusions) when is_list(Incl) ->
    should_include(Incl, Exclusions);
should_include(Incl, Exclusions) ->
    not lists:any(fun(Ex) -> lists:prefix(Ex, Incl) end, Exclusions).

merge_templates(MaybeTemplates, Opts) ->
    Vars = case proplists:get_value(vars_file, Opts) of
        undefined ->
            dict:new();
        Path ->
            case file:consult(Path) of
                {error, _} ->
                    dict:new();
                {ok, Terms} ->
                    dict:from_list(Terms)
            end
    end,
    lists:map(fun(F) -> apply_template(F, Vars) end, MaybeTemplates).

apply_template({#spec{template=true}=Spec, File}, Vars) ->
    {ok, Bin} = file:read_file(File),
    {Spec, {File, list_to_binary(rebar_templater:render(Bin, Vars))}};
apply_template(Entry, _) ->
    Entry.

%% TODO: handle *mode* by doing a(ny) chmod/chown/chgrp in a work directory

merge_paths({_, {File, _Data}}=E, Acc) ->
    merge_paths(File, Acc, E);
merge_paths({_, File}=E, Acc) ->
    merge_paths(File, Acc, E).

merge_paths(File, Acc, E) ->
    case lists:keyfind(File, 2, Acc) of
        false ->
            [E|Acc];
        _ ->
            lists:keyreplace(File, 2, Acc, E)
    end.

flatten_entries([{Spec, [H|_]=Entry}|Rest]) when is_integer(H) ->
    [{Spec, Entry}|flatten_entries(Rest)];
flatten_entries([{Spec, [H|_]=Entries}|Rest]) when is_list(H) ->
    [ {Spec, E} || E <- Entries ] ++ flatten_entries(Rest);
flatten_entries([[H|_]=First|Rest]) when is_integer(H) ->
    [First|flatten_entries(Rest)];
flatten_entries([[H|T]|Rest]) when is_list(H) ->
    lists:concat([[H], flatten_entries(T), flatten_entries(Rest)]);
flatten_entries([[]|Rest]) ->
    flatten_entries(Rest);
flatten_entries([]) ->
    [].

collect_dirs(Incl) ->
    flatten_entries(collect_glob(fun process_dir/2, Incl)).

collect_files(Incl) ->
    collect_glob(fun process_files/2, Incl).

collect_glob(Proc, Globs) ->
    Cwd = rebar_utils:get_cwd(),
    Dirs = lists:duplicate(length(Globs), Cwd),
    {_MapAcc, FoldAcc} =
        lists:foldl(process_glob(Proc), {[], []},
                    lists:zip(Dirs, Globs)),
    FoldAcc.

process_files(Dir, Glob) ->
    Files = rebar_utils:find_files(Dir, Glob) ++
        [ filename:join(Dir, E) || E <- filelib:wildcard(Glob) ],
    Files.

process_dir(Dir, {fnmatch, Glob}) ->
    case file:list_dir(Dir) of
        [] -> [];
        {ok, Entries} ->
            Paths = [ filename:join(Dir, E) || E <- Entries ],
            {Dirs, Files} = lists:partition(fun filelib:is_dir/1,
                                lists:filter(glob_filter(Glob), Paths)),
            Found = lists:concat([[ process_dir(D) || D <- Dirs ], Files]),
            lists:filter(glob_filter(Glob), flatten_entries(Found))
    end;
process_dir(Dir, Glob) ->
    Entries = [ filename:join(Dir, D) || D <- filelib:wildcard(Glob) ],
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Entries),
    lists:concat([[ process_dir(D) || D <- Dirs ], Files]).

glob_filter(Glob) when is_function(Glob) ->
    fun(D) ->
        case Glob(D) of
            true -> true;
            {true, _} -> true;
            _ -> false
        end
    end.

process_dir(Dir) ->
    case file:list_dir(Dir) of
        [] -> [];
        {ok, Entries} ->
            Paths = [filename:join(Dir, E) || E <- Entries],
            {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
        flatten_entries(
            [ E || E <- lists:concat([[ process_dir(D) || D <- Dirs ], Files]),
                   not filelib:is_dir(E) ])
    end.

process_glob(Proc) ->
    fun({Dir, #spec{path=Path, glob=undefined}=Spec}, {MapAcc, FoldAcc}) ->
            no_duplicates(Spec, [filename:join(Dir, Path)], MapAcc, FoldAcc);
       ({Dir, #spec{glob=Glob}=Spec}, {MapAcc, FoldAcc}) ->
            no_duplicates(Spec, Proc(Dir, Glob), MapAcc, FoldAcc);
       ({Dir, PathExpr}, {MapAcc, FoldAcc}) when is_list(PathExpr) ->
            no_duplicates(glob(PathExpr), Proc(Dir, PathExpr),
                          MapAcc, FoldAcc)
    end.

no_duplicates(Spec, Entries, SoFar, Result) ->
    New = [ E || E <- Entries, not lists:member(E, SoFar) ],
    Processed = lists:concat([New, SoFar]),
    WithSpecs = lists:concat([[ {Spec, N} || N <- New ], Result]),
    {Processed, WithSpecs}.

ensure_path(Dir) ->
    rebar_utils:ensure_dir(Dir),
    ok = case filelib:is_dir(Dir) of
        true ->
            ok;
        false ->
            file:make_dir(Dir)
    end,
    Dir.

outdir(Opts) ->
    proplists:get_value(outdir, Opts, "dist").

find_assemblies(#conf{ base=Base, dist=DistConfig }) ->
    case lists:filter(fun(X) -> element(1, X) == assembly end, DistConfig) of
        [] ->
            [#assembly{name=Base, opts=DistConfig}];
        Assemblies ->
            Assemblies
    end.

scope_config(undefined, Config) ->
    App = basename(),
    BaseConfig = rebar_config:get_list(Config, dist, []),
    {App, [{app, App}|merge_config(BaseConfig)]};
scope_config(AppFile, Config) ->
    App = rebar_app_utils:app_name(AppFile),
    BaseConfig = rebar_config:get_list(Config, dist, []),
    {App, [{app, App}|merge_config(BaseConfig)]}.

merge_config(BaseConfig) ->
    NewBase = case lists:keyfind(config, 1, BaseConfig) of
        {config, ConfigPath} ->
            case load_assembly(ConfigPath, assembly_merge(BaseConfig)) of
                {ok, Assemblies} ->
                    Assemblies;
                {error, Other} ->
                    ?WARN("Failed to load ~s: ~p\n", [ConfigPath, Other]),
                    BaseConfig
            end;
        _Other ->
            BaseConfig
    end,
    FinalAssemblies = (assembly_merge(NewBase))(base_assemblies(NewBase)),
    write_globals(FinalAssemblies, BaseConfig).

write_globals(Assemblies, BaseConfig) ->
    lists:map(write_globals(BaseConfig), Assemblies).

write_globals(BaseConfig) ->
    Rewrites = [format, version, incl_dirs, incl_files, excl_dirs, excl_files],
    fun(#assembly{opts=Opts}=A) ->
        %Format = proplists:get_value(format, BaseConfig, undefined),
        %Version = proplists:get_value(version, BaseConfig, undefined),
        %ReFormatted = overwrite({format, Format}, Opts),
        %ReVersioned = overwrite({version, Version}, ReFormatted),
        %A#assembly{opts=ReVersioned};
        Updated = lists:foldl(rewrite_opts(BaseConfig), Opts, Rewrites),
        A#assembly{opts=Updated};
       (Other) -> Other
    end.

rewrite_opts(BaseConfig) ->
    fun(Key, Opts) ->
        Replacement = proplists:get_value(Key, BaseConfig, undefined),
        overwrite({Key, Replacement}, Opts)
    end.

overwrite({Key, [_|_]=Value}, Opts) when Key == incl_dirs orelse
                                   Key == incl_files orelse
                                   Key == excl_dirs orelse 
                                   Key == excl_files ->
    case lists:keyfind(Key, 1, Opts) of
        false ->
            [{Key, Value}|Opts];
        {Key, Config} when is_list(Config) ->
            lists:keyreplace(Key, 1, Opts, {Key, Value ++ Config});
        _ ->
            lists:keyreplace(Key, 1, Opts, {Key, Value})
    end;
overwrite({_Key, []}, Opts) ->
    Opts;
overwrite({_Key, undefined}, Opts) ->
    Opts;
overwrite({Key, Value}, Opts) ->
    case lists:keyfind(Key, 1, Opts) of
        false ->
            [{Key, Value}|Opts];
        _ ->
            lists:keyreplace(Key, 1, Opts, {Key, Value})
    end.

base_assemblies(ReferencedAssemblies) ->
    Dir = filename:join(code:priv_dir(rebar_dist_plugin), "assemblies"),
    ?DEBUG("Loading pre-defined assemblies from ~s~n", [Dir]),
    case file:list_dir(Dir) of
        {ok, Dirs} ->
            Bases = [ list_to_atom(filename:basename(D, ".config")) || D <- Dirs ],
            Assemblies = lists:concat(lists:map(fun load_assembly/1,
                                    [ filename:join(Dir, P) || P <- Dirs ])),
            [ {Assembly, Data} || {Assembly, Data} <- lists:zip(Bases, Assemblies),
                                  lists:keymember(Assembly, 2, ReferencedAssemblies) ];
        _ ->
            []
    end.

assembly_merge(BaseConfig) ->
    fun(Assemblies) ->
        lists:foldl(fun merge_assemblies/2, BaseConfig, Assemblies)
    end.

load_assembly(ConfigPath) ->
    case load_assembly(ConfigPath, fun(X) -> X end) of
        {ok, Assembly} when is_tuple(Assembly) ->
            [Assembly];
        {ok, Assemblies} when is_list(Assemblies) ->
            Assemblies;
        {error, _Other} ->
            []
    end.

load_assembly(ConfigPath, Loader) ->
    case read_conf(ConfigPath) of
        {ok, {dist, Terms}, _Path} ->
            Assemblies = [ A || A <- Terms, element(1, A) =:= assembly ],
            {ok, Loader(Assemblies)};
        Other ->
            ?WARN("Config Load Error: ~p~n", [Other]),
            {error, Other}
    end.

merge_assemblies({Name, E}, Acc) when is_atom(Name) ->
    lists:keyreplace(Name, 2, Acc, E);
merge_assemblies(E, Acc) ->
    lists:keyreplace(E#assembly.name, 2, Acc, E).

read_conf(File) ->
    Bs = erl_eval:new_bindings(),
    case file:path_open([rebar_utils:get_cwd()], File, [read]) of
    {ok,Fd,Full} ->
        case eval_stream(Fd, return, Bs) of
            {ok,R} ->
                file:close(Fd),
                {ok, R, Full};
            E1 ->
                file:close(Fd),
                E1
        end;
    E2 ->
        E2
    end.

config_fn_handler(Name, Arguments) ->
    apply(?MODULE, Name, Arguments).

ext_config_fn_handler(Func, Args) when is_function(Func) ->
    Func(Args);
ext_config_fn_handler({Mod, Func}, Args) ->
    apply(Mod, Func, Args).

eval_stream(Fd, Handling, Bs) ->
    eval_stream(Fd, Handling, 1, undefined, [], Bs).

eval_stream(Fd, H, Line, Last, E, Bs) ->
    eval_stream2(io:parse_erl_exprs(Fd, '', Line), Fd, H, Last, E, Bs).

eval_stream2({ok,Form,EndLine}, Fd, H, Last, E, Bs0) ->
    try erl_eval:exprs(Form, Bs0, {value, fun config_fn_handler/2},
                                  {value, fun ext_config_fn_handler/2}) of
        {value,V,Bs} ->
            eval_stream(Fd, H, EndLine, {V}, E, Bs)
    catch Class:Reason ->
        Error = {EndLine,?MODULE,{Class,Reason,erlang:get_stacktrace()}},
        eval_stream(Fd, H, EndLine, Last, [Error|E], Bs0)
    end;
eval_stream2({error,What,EndLine}, Fd, H, Last, E, Bs) ->
    eval_stream(Fd, H, EndLine, Last, [What | E], Bs);
eval_stream2({eof,EndLine}, _Fd, H, Last, E, _Bs) ->
    case {H, Last, E} of
        {return, {Val}, []} ->
            {ok, Val};
        {return, undefined, E} ->
            {error, hd(lists:reverse(E, [{EndLine,?MODULE,undefined_script}]))};
        {ignore, _, []} ->
            ok;
        {_, _, [_|_] = E} ->
            {error, hd(lists:reverse(E))}
    end.
