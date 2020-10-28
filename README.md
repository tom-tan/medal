# Medal
[![build](https://github.com/tom-tan/medal/workflows/CI/badge.svg?branch=master)](https://github.com/tom-tan/medal/actions)

This is a workflow engine based on Petri nets.

## Usage

See `medal --help` for more details.
```console
$ medal -h
Medal: A workflow engine based on Petri nets
Usage: medal [options] <network.yml>
-i --init Specify initial marking file
-h --help This help information.
```

See:
- `examples/transition.yml` for input transitions.
- `examples/transition-input.yml` for initial marking.

Note: the syntax is not fixed yet.



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
