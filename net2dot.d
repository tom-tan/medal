#!/usr/bin/env dub
/+ dub.sdl:
    name "net2dot"
    dependency "dyaml" version="~>0.8.2"
+/
import std;
import dyaml;

alias Edge = Tuple!(string, string, string);

void main(string[] args)
{
    if (args.length != 3)
    {
        writefln("Usage: %s <input.yml> <output.dot>\n", args[0]);
        return;
    }
    auto inp = args[1];
    enforce(inp.exists, "Input not found: "~inp);
    auto out_dot = args[2];

    auto trs = redBlackTree!string();
    auto places = redBlackTree!string();
    Edge[] edges;

    auto root = Loader.fromFile(inp).load;
    auto type = enforce("type" in root, "`type` field is needed").get!string;

    switch(type)
    {
    case "shell":
        transition2dot(root, trs, places, edges);
        break;
    case "network":
        network2dot(root, trs, places, edges);
        break;
    default:
        enforce(false, "Unknown type: "~type);
    }

    File(out_dot, "w").writeln(to_dot(trs, places, edges));
}

void transition2dot(Node n, 
                    ref RedBlackTree!string trs,
                    ref RedBlackTree!string places,
                    ref Edge[] edges)
{
    auto name = enforce("name" in n, "`name` field is needed").get!string;
    trs.insert(name);

    if (auto inp = "in" in n)
    {
        inp.sequence.each!((i) {
            auto ip = enforce("place" in i, "`place` field is needed").get!string;
            places.insert(ip);
            auto pat = enforce("pattern" in i, "`pattern` field is needed").get!string;
            edges ~= tuple(ip, name, "="~pat);
        });
    }
    if (auto outs = "out" in n)
    {
        outs.sequence.each!((o) {
            auto op = enforce("place" in o, "`place` field is needed").get!string;
            places.insert(op);
            auto pat = enforce("pattern" in o, "`pattern` field is needed").get!string;
            edges ~= tuple(name, op, pat);
        });
    }
    
}

void network2dot(Node n, 
                 ref RedBlackTree!string trs,
                 ref RedBlackTree!string places,
                 ref Edge[] edges)
{
    auto ts = enforce("transitions" in n, "`transitions` field is needed").sequence;
    ts.each!(t => transition2dot(t, trs, places, edges));
    if (auto outs = "out" in n)
    {
        auto end = "_end_";
        trs.insert(end);
        outs.sequence.each!((o) {
            auto op = enforce("place" in o, "`place` field is needed").get!string;
            places.insert(op);
            auto pat = enforce("pattern" in o, "`pattern` field is needed").get!string;
            edges ~= tuple(op, end, pat);
        });
    }
}

auto to_dot(RedBlackTree!string trs,
            RedBlackTree!string places,
            Edge[] edges)
{
    return format!q"EOS
digraph G {
%s
%s
}
EOS"(trs[].map!(t => format!`"%s" [shape = box];`(t)).joiner(" ").array,
     edges.map!(e => format!`"%s" -> "%s" [label="%s"];`(e.expand)).joiner(" ").array);
}