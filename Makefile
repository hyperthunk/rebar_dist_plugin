#!/usr/bin/make -f
# Makefile wrapper

all: clean-build

build:
	@(./rebar compile)

clean:
	@(./rebar clean)

clean-build: clean build

test: test-deps
	@(./rebar -C test.config retest -v)

test-deps:
	@(./rebar -C test.config get-deps compile-deps)

.PHONY: all build clean clean-build test
