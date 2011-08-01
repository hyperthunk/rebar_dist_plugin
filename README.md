# Rebar Dist Plugin

This plugin allows you to package up a (configurable) set of files into a
compressed archive (i.e. .tar.gz or .zip). The plugin's rebar configuration
supports wildcards in both relative and absolute paths for files and directories,
output path/file name and will allow you to make multiple files if so required.

The plugin exports a new `dist` command, an will also run in response to the
`generate` and `clean` commands, although this behaviour is configurable (e.g. if
you wish to ignore the `generate` command and only run when `dist` is explicitly
given on the command line).

## Installation

Include the following tuple in your rebar deps:

```erlang
{deps, [{rebar_dist_plugin, ".*", {git,
    "git://github.com/hyperthunk/rebar_dist_plugin.git", "master"}}]}.
```

Then you will be able to fetch and install the plugin (locally) with rebar:

    user@host$ rebar get-deps compile
    user@host$ rebar dist skip_deps=true

Alternatively, you may put the plugin into your `ERL_LIBS` path somewhere and
use it in many projects. This can be done manually, or using a package manager:

    user@host$ epm install hyperthunk/rebar-dist-plugin  # or
    user@host$ sutro install hyperthunk/rebar-dist-plugin

## Usage

Configure the dist plugin in your `rebar.config` as usual:

```erlang
{rebar_plugins, [rebar_dist_plugin]}.
{dist, [Options]}.
```

See the [wiki](https://github.com/hyperthunk/rebar_dist_plugin/wiki) for details
on the various options (and commands).

You execute the plugin like any other rebar command:

    rebar clean generate    # if you're hooked into a release
    rebar distclean dist    # if you wish to explicitly assemble a distribution

## Running the tests

The project ships with a `Makefile` wrapper that will execute a bunch of tests
against the examples directory using the [rebar_retest_plugin](https://github.com/hyperthunk/rebar_retest_plugin). As this
configuration has separate dependencies (for test only), the simplest way to run
these is to execute `make test` on the command line.
