# Medal
[![build](https://github.com/tom-tan/medal/workflows/CI/badge.svg?branch=master)](https://github.com/tom-tan/medal/actions) [![license](https://badgen.net/github/license/tom-tan/medal)](https://github.com/tom-tan/medal/blob/master/LICENSE)

This is a workflow engine based on Petri nets.

## Usage

```console
$ medal examples/network.yml -i examples/network-input.yml
```
It requires a file that describes a network (workflow) and a file that specifies the initial marking (optional).

See `medal --help` for more details.
```console
$ ./bin/medal --help
Medal: A workflow engine based on Petri nets
Usage: ./bin/medal [options] <network.yml>
-i  --init Specify initial marking file
   --quiet Do not print any logs
   --debug Enable debug logs
     --log Specify log destination (default: stderr)
-h  --help This help information.
```

The `examples` directory shows several examples.
Each directory contains `network.yml` for a network and `init.yml` for initial marking.
- `transition` shows how to write a transition
- `network` shows how to write a network
- `passthrough` shows how to pass a token in a place to other places

You can visualize a given network by using `net2dot.d` with the following commands:

```console
$ ./net2dot.d examples/network/network.yml output.dot # dub is required
$ dot -T pdf output.dot -o network.pdf # Graphviz is required
```

Note: syntax is not fixed yet.

## For developers
### Build requirements
- D compiler
- dub

or

- Docker (only for Linux)

### How to build

```console
$ git clone https://github.com/tom-tan/medal.git
$ cd medal
$ dub build -b release
```

or

```console
$ git clone https://github.com/tom-tan/medal.git
$ cd medal
$ docker run --rm -v ${PWD}:/medal --workdir=/medal dlang2/ldc-ubuntu dub build -b release
```


You will see `medal` in `bin` directory.

### How to dive into source codes
```console
$ dub run gendoc
```

You will see API documents (HTML) in `docs` directory.

# LICENSE

This repository is licensed under [Apache 2.0](LICENSE) except for [process.d](source/medal/utils/process.d) that is licensed under Boost License 1.0.
