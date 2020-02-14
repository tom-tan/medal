import std;
import dyaml;
import engine = medal.engine;
static import medal.parser;

import std.experimental.logger;

int main(string[] args) // @safe
{
    globalLogLevel = LogLevel.off;
    auto helpInfo = args.getopt(
        "quiet", () => globalLogLevel = LogLevel.off,
        "verbose|v", () => globalLogLevel = LogLevel.info,
        "veryverbose", () => globalLogLevel = LogLevel.all,
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
    auto params = medal.parser.parse(root);
    return engine.run(params.store, params.rules, params.initEvent);
}
