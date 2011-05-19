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
-export([dist/2, distclean/2]).
-export([generate/2, clean/2]).

-export([glob/1, spec/2, name/1]).
-export([template/1, template/2]).

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
    %% AppName will be the default output filename
    rebar_config:set_global(skip_deps, 1),
    {App, DistConfig} = scope_config(AppFile, Config),
    dist(#conf{ base=App, rebar=Config, dist=DistConfig }).

distclean(Config, AppFile) ->
    {_, DistConfig} = scope_config(AppFile, Config),
    Outdir = outdir(DistConfig),
    rebar_file_utils:rm_rf(Outdir).

generate(Config, AppFile) ->
    rebar_log:log(debug, "Dist Plugin `generate' ~p~n", [Config]),
    Attach = rebar_config:get_local(Config, attach, []),
    case lists:member(generate, Attach) of
        true ->
            dist(Config, AppFile);
        false ->
            ok
    end.

clean(Config, AppFile) ->
    rebar_log:log(debug, "Dist Plugin `generate' ~p~n", [Config]),
    Attach = rebar_config:get_local(Config, attach, []),
    case lists:member(clean, Attach) of
        true ->
            distclean(Config, AppFile);
        false ->
            ok
    end.

dist(Conf) ->
    Results = [ process_assembly(A) || A <- find_assemblies(Conf) ],
    Errors = [R || R <- Results, R =/= ok],
    case (length(Errors) > 0) of
        true ->
            {error, Errors};
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

%%spec(Glob, Mode, Owner, Group) ->
%%    #spec{glob=Glob, mode={Mode, Owner, Group}}.

%%spec(Glob, Target, Mode, Owner, Group) ->
%%    #spec{glob=Glob, target=Target, mode={Mode, Owner, Group}}.



%%
%% Internal API
%%

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

write_assembly(zip, Name, Outdir, MergedFsEntries, _Conf) ->
    ensure_path(Outdir),
    Opts = case rebar_config:is_verbose() of
        true ->
            [verbose];
        _ ->
            []
    end,
    Filename = filename:join(Outdir, Name) ++ ".zip",
    Result = zip:create(Filename, MergedFsEntries, Opts),
    %% TODO: reconstruct the template entries in memory before writing to disk
    ?DEBUG("Result: ~p~n", [Result]),
    Result;
write_assembly(tar, Name, Outdir, MergedFsEntries, Conf) ->
    ensure_path(Outdir),
    Opts = case rebar_config:is_verbose() of
        true ->
            [write, compressed, verbose];
        _ ->
            [write, compressed]
    end,
    Filename = filename:join(Outdir, Name) ++ ".tar.gz",
    %% -record(entry, {spec, source, target, data, info}).
    Prefix = proplists:get_value(prefix, Conf, Name),
    Entries = [ tar_entry(E, Prefix) || E <- MergedFsEntries ],
    case rebar_config:get_global(dryrun, false) of
        false ->
            erl_tar:create(Filename, Entries, Opts);
        _ ->
            print_assembly(Filename, Entries),
            ok
    end.

print_assembly(Filename, Entries) ->
    io:format("INFO:  [~p] ==> Create-Archive: ~s~n", [?MODULE, Filename]),
    lists:map(fun print_entry/1, Entries).

print_entry(E) ->
    io:format("INFO:  [~p] ==> Archive-Entry: ~p~n", [?MODULE, E]).

%% TODO: to write a directory into the tar with a different name, we will need
%% to (recursively) copy it to a "work area" with the new name

tar_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=directory}}, Prefix) when Src /= Targ ->
    {target(Prefix, Targ), Src};
tar_entry(#entry{source=Src, info=#file_info{type=directory}}, Prefix) ->
    target(Prefix, Src);
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
    ?DEBUG("Creating Archive Entry for ~p~n", [File]),
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
        Target ->
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
flatten_entries([]) ->
    [].

collect_dirs(Incl) ->
    ?DEBUG("Collecting dirs matching ~p~n", [Incl]),
    Dirs = collect_glob(fun process_dir/2, Incl),
    flatten_entries(Dirs).

collect_files(Incl) ->
    ?DEBUG("Collecting files matching ~p~n", [Incl]),
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

process_dir(Dir, Glob) ->
    Entries = [ filename:join(Dir, D) || D <- filelib:wildcard(Glob) ],
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Entries),
    Found = lists:concat([[ process_dir(D) || D <- Dirs ], Files]),
    Found.

process_dir(Dir) ->
    ?DEBUG("Processing dir ~p~n", [Dir]),
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

basename() ->
    filename:basename(rebar_utils:get_cwd()).

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
    case lists:keyfind(config, 1, BaseConfig) of
        {config, ConfigPath} ->
            case read_conf(ConfigPath) of
               {ok, {dist, Terms}, _Path} ->
                   %% all non-assembly members are ignored
                   Assemblies = [ A || A <- Terms, element(1, A) =:= assembly ],
                   lists:foldl(fun merge_assemblies/2, BaseConfig, Assemblies);
               Other ->
                   ?WARN("Failed to load ~s: ~p\n", [ConfigPath, Other]),
                   BaseConfig
            end;
        _Other ->
            BaseConfig
    end.

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

eval_stream(Fd, Handling, Bs) ->
    eval_stream(Fd, Handling, 1, undefined, [], Bs).

eval_stream(Fd, H, Line, Last, E, Bs) ->
    eval_stream2(io:parse_erl_exprs(Fd, '', Line), Fd, H, Last, E, Bs).

eval_stream2({ok,Form,EndLine}, Fd, H, Last, E, Bs0) ->
    try erl_eval:exprs(Form, Bs0, {value, fun config_fn_handler/2}) of
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
