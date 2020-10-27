module medal.loader;

import medal.transition;
import medal.network;

import dyaml;

import std;

///
Transition loadTransition(Node node)
{
    auto type = (*enforce("type" in node)).as!string;
    switch(type)
    {
    case "shell":
        return loadShellCommandTransition(node);
    case "network":
        return loadInvocationTransition(node);
    default:
        assert(false, "Unknown type: "~type);
    }
}

///
Transition loadShellCommandTransition(Node node)
in("type" in node)
in(node["type"].as!string == "shell")
do
{
    auto command = (*enforce("command" in node)).as!string;
    enforce(!command.empty);
    auto name = (*enforce("name" in node)).as!string;
    auto g = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto aef = "out" in node ? loadArcExpressionFunction(node["out"])
                             : ArcExpressionFunction.init;
    return new ShellCommandTransition(command, g, aef);
}

///
Transition loadInvocationTransition(Node node)
in("type" in node)
in(node["type"].as!string == "network")
do
{
    auto name = (*enforce("name" in node)).as!string;
    auto trNodes = (*enforce("transitions" in node)).sequence.array;
    auto trs = new Generator!Node({
        foreach(Node n; node["transitions"])
        {
            yield(n);
        }
    }).map!loadTransition.array;
    enforce(!trs.empty);

    auto g1 = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto g2 = "out" in node ? loadGuard(node["out"]) : Guard.init;
    return new InvocationTransition(g1, g2, trs);
}

unittest
{
    enum inpStr = q"EOS
    name: echo
    type: shell
    out:
      - place: ret
        pattern: RETURN
    command: true
EOS";
    auto trRoot = Loader.fromString(inpStr).load;
    auto tr = loadTransition(trRoot);
    assert(cast(ShellCommandTransition)tr);
    spawnFire(tr, new BindingElement, thisTid);
    auto received = receiveTimeout(10.seconds,
        (in BindingElement be) {
            assert(be == [Place("ret"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
    assert(received);
}

Guard loadGuard(Node node)
{
    auto pats = new Generator!(Tuple!(Place, InputPattern))({
        foreach(Node n; node)
        {
            auto pl = (*enforce("place" in n)).as!string;
            auto pat = (*enforce("pattern" in n)).as!string;
            yield(tuple(Place(pl), InputPattern(pat)));
        }
    }).assocArray;
    return pats.assumeUnique;
}

ArcExpressionFunction loadArcExpressionFunction(Node node)
{
    auto pats = new Generator!(Tuple!(Place, OutputPattern))({
        foreach(Node n; node)
        {
            auto pl = (*enforce("place" in n)).as!string;
            auto pat = (*enforce("pattern" in n)).as!string;
            yield(tuple(Place(pl), OutputPattern(pat)));
        }
    }).assocArray;
    return pats.assumeUnique;
}

unittest
{
    enum inpStr = q"EOS
    - place: pl
      pattern: constant-value
EOS";
    auto root = Loader.fromString(inpStr).load;
    auto g = loadGuard(root);
    assert(g == cast(immutable)[Place("pl"): InputPattern("constant-value")]);
}

BindingElement loadBindingElement(Node node)
{
    auto tokenElems = new Generator!(Tuple!(Place, Token))({
        foreach(string pl, string tok; node)
        {
            yield(tuple(Place(pl), new Token(tok)));
        }
    }).assocArray;
    return new BindingElement(tokenElems.assumeUnique);
}