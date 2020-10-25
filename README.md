# Medal
[![build](https://github.com/tom-tan/medal/workflows/CI/badge.svg?branch=master)](https://github.com/tom-tan/medal/actions)

This is a state transition engine based on Flux.

## Build requirements
- D compiler
- dub

## How to build

```console
$ git clone https://github.com/tom-tan/medal.git
$ cd medal
$ dub build -b release
```

You will see `medal` in `bin` directory.

## Usage

See `medal --help` for more details.
```console
$ medal [options] <input.yml>
```

See `examples/simple.yml` for the input syntax.

Note: the syntax is not fixed yet.
