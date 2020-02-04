import std;
import dyaml;
import medal.engine;

import std.experimental.logger;

int main(string[] args)
{
    auto logLevel = 1;
    void verboseHandler(string opt, string value)
    {
        switch(value)
        {
        case "quiet":             logLevel = 0; break;
        case "verbose", "v":      logLevel = 2; break;
        case "veryverbose", "vv": logLevel = 3; break;
        default:                  logLevel = 1; break;
        }
    }
    auto helpInfo = args.getopt(
        "quiet", &verboseHandler,
        "verbose|v", &verboseHandler,
        "veryverbose|vv", &verboseHandler,
    );
    if (helpInfo.helpWanted || args.length != 2)
    {
        immutable baseMessage = format(q"EOS
        Medal: a Flux-based state transition engine
        Usage: %s [options] <yaml>
EOS".outdent[0..$-1], args[0]);
        // 以下は @safe であるべき！
        defaultGetoptPrinter(baseMessage, helpInfo.options);
        return 0;
    }

    immutable yaml = args[1];
    if (!yaml.exists)
    {
        error("Input file is not found: ", yaml);
        return 1;
    }
    Node root = Loader.fromFile(yaml).load;
    foreach(Node action; root["action-creator"]) 
    {
        info(action["type"].as!string);
    }
    // 
    // construct store, event rules and init state
    // run it
    return 0;
}
