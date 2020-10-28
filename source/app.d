import std;
import dyaml;

import medal.loader;
import medal.transition;

int main(string[] args)
{
    string initFile;
    auto helpInfo = args.getopt(
        std.getopt.config.caseSensitive,
        "init|i", "Specify initial marking file", &initFile,
    );
    if (helpInfo.helpWanted || args.length != 2)
    {
        immutable baseMessage = format(q"EOS
        Medal: A workflow engine based on Petri nets
        Usage: %s [options] <network.yml>
EOS".outdent[0..$-1], args[0]);
        defaultGetoptPrinter(baseMessage, helpInfo.options);
        return 0;
    }

    auto netFile = args[1];
    if (!netFile.exists)
    {
        stderr.writeln("Network file is not found: "~netFile);
        return 1;
    }
    Node netRoot = Loader.fromFile(netFile).load;
    auto tr = loadTransition(netRoot);

    Rebindable!BindingElement initBe;
    if (initFile.exists)
    {
        Node initRoot = Loader.fromFile(initFile).load;
        initBe = loadBindingElement(initRoot);
    }
    else if (initFile.empty)
    {
        initBe = new BindingElement;
    }
    else
    {
        stderr.writeln("Initial marking file is not found: "~initFile);
        return 1;
    }

    auto mainTid = spawnFire(tr, initBe, thisTid);

    bool success;
    receive(
        (in BindingElement be) {
            writeln("Received: ", be);
            success = true;
        },
        (in SignalSent ss) {
            writefln("Signal %s is caught", ss.no);
            success = false;
        },
        (shared Exception e) {
            writefln("Exception in %s(%s): %s", e.file, e.line, e.msg);
            success = false;
        },
        (Variant v) {
            writeln("Error: ", v);
            success = false;
        },
    );
    return success ? 0 : 1;
}
