#!/usr/bin/env dub
/+ dub.sdl:
    name "net2dot"
    targetPath "bin"
    dependency "dyaml" version="~>0.8.2"
    buildType "release-static" {
		buildOptions "releaseMode" "optimize" "inline"
		dflags "-static" platform="posix-ldc"
    }
+/
/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
import std;
import dyaml;

struct Edge
{
    this(string src, string dst, string[] attrs = [])
    {
        this.src = src;
        this.dst = dst;
        this.attrs = attrs;
    }

    auto toDot()
    {
        auto prop = attrs.empty ? "" : format!`[%-(%s,%)]`(attrs);
        return  format!`"%s" -> "%s" %s;`(src, dst, prop);
    }

    string src, dst;
    string[] attrs;
}

void main(string[] args)
{
    if (args.length != 3)
    {
        writefln("Usage: %s <input.yml> <output.dot>\n", args[0].baseName);
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

    transition2dot(root, trs, places, edges, "");
    File(out_dot, "w").writeln(toDot(trs, places, edges));
}

void transition2dot(Node node,
                    ref RedBlackTree!string trs,
                    ref RedBlackTree!string places,
                    ref Edge[] edges, string extraProps)
{
    auto type = enforce("type" in node, "`type` field is needed").get!string;
    switch(type)
    {
    case "shell":
        shell2dot(node, trs, places, edges, extraProps);
        break;
    case "network":
        network2dot(node, trs, places, edges, extraProps);
        break;
    case "invocation":
        invocation2dot(node, trs, places, edges, extraProps);
        break;
    default:
        enforce(false, "Unknown type: "~type);
    }
}

void shell2dot(Node n,
               ref RedBlackTree!string trs,
               ref RedBlackTree!string places,
               ref Edge[] edges,
               string extraProps)
{
    auto name = enforce("name" in n, "`name` field is needed").get!string;
    trs.insert(name);

    if (auto inp = "in" in n)
    {
        inp.sequence.each!((i) {
            auto ip = enforce("place" in i, "`place` field is needed").get!string;
            places.insert(ip);
            auto pat = enforce("pattern" in i, "`pattern` field is needed").get!string;
            auto props = [format!`label="=%s"`(pat)];
            if (!extraProps.empty)
            {
                props ~= extraProps;
            }
            edges ~= Edge(ip, name, props);
        });
    }
    if (auto outs = "out" in n)
    {
        outs.sequence.each!((o) {
            auto op = enforce("place" in o, "`place` field is needed").get!string;
            places.insert(op);
            auto pat = enforce("pattern" in o, "`pattern` field is needed in "~name).get!string;
            auto props = [format!`label="=%s"`(pat)];
            if (!extraProps.empty)
            {
                props ~= extraProps;
            }
            edges ~= Edge(name, op, props);
        });
    }
}

void network2dot(Node n,
                 ref RedBlackTree!string trs,
                 ref RedBlackTree!string places,
                 ref Edge[] edges,
                 string extraProps)
{
    auto ts = enforce("transitions" in n, "`transitions` field is needed").sequence;
    ts.each!(t => transition2dot(t, trs, places, edges, extraProps));
    if (auto outs = "out" in n)
    {
        auto end = "_end_";
        trs.insert(end);
        outs.sequence.each!((o) {
            auto op = enforce("place" in o, "`place` field is needed").get!string;
            places.insert(op);
            auto pat = enforce("pattern" in o, "`pattern` field is needed").get!string;
            auto props = [format!`label="%s"`(pat)];
            if (!extraProps.empty)
            {
                props ~= extraProps;
            }
            edges ~= Edge(op, end, props);
        });
    }

    if (auto on = "on" in n)
    {
        if (auto success = "success" in *on)
        {
            success.sequence.each!(t => transition2dot(t, trs, places, edges, "style=dashed"));
        }
        if (auto failure = "failure" in *on)
        {
            failure.sequence.each!(t => transition2dot(t, trs, places, edges, "style=dotted"));
        }
        if (auto exit = "exit" in *on)
        {
            exit.sequence.each!(t => transition2dot(t, trs, places, edges, "style=dashed"));
            exit.sequence.each!(t => transition2dot(t, trs, places, edges, "style=dotted"));
        }
    }
}

void invocation2dot(Node n,
                    ref RedBlackTree!string trs,
                    ref RedBlackTree!string places,
                    ref Edge[] edges,
                    string extraProps)
{
    auto name = enforce("name" in n, "`name` field is needed").get!string;
    trs.insert(name);

    if (auto inp = "in" in n)
    {
        inp.sequence.each!((i) {
            auto ip = enforce("place" in i, "`place` field is needed").get!string;
            places.insert(ip);
            auto pat = enforce("pattern" in i, "`pattern` field is needed").get!string;
            auto props = [format!`label="%s"`(pat)];
            if (!extraProps.empty)
            {
                props ~= extraProps;
            }
            edges ~= Edge(ip, name, props);
        });
    }
    if (auto outs = "out" in n)
    {
        outs.sequence.each!((o) {
            auto port = enforce("port-to" in o, "`port-to` field is needed in "~name).get!string;
            places.insert(port);
            auto op = enforce("place" in o, "`place` field is needed").get!string;
            auto props = [format!`label="net.%s"`(op)];
            if (!extraProps.empty)
            {
                props ~= extraProps;
            }
            edges ~= Edge(name, port, props);
        });
    }
}

auto toDot(RedBlackTree!string trs,
           RedBlackTree!string places,
           Edge[] edges)
{
    return format!q"EOS
digraph G {
%s
%s
}
EOS"(trs[].map!(t => format!`"%s" [shape = box];`(t)).joiner(" ").array,
     edges.map!(e => e.toDot).joiner(" ").array);
}
