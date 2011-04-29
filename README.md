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

    {deps, [{'rebar-dist-plugin', ".*", {git, 
        "git://github.com/hyperthunk/rebar-dist-plugin.git", "master"}}]}.

Then you will be able to fetch and install the plugin (locally) with rebar:

    rebar get-deps compile

## Usage

Configure the dist plugin in your `rebar.config` as usual:

    {dist, [Options]}.

See the [wiki](https://github.com/hyperthunk/rebar-dist-plugin/wiki) for details
on the various options (and commands).

You execute the plugin like any other rebar command:

    rebar clean generate    # if you're hooked into a release
    rebar dist              # if you wish to explicitly assemble a distribution
