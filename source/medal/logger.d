/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.logger;

import medal.config : Config;

import std.datetime.timezone : TimeZone;
import std.json : JSONValue;
import std.stdio : File;
import std.typecons : Tuple;

public import std.experimental.logger : LogLevel, Logger, NullLogger, sharedLog;

///
enum LogType
{
    System,
    App,
}

///
Logger[LogType] nullLoggers() @safe {
    return [
        LogType.System: new NullLogger,
        LogType.App: new NullLogger,
    ];
}

///
@safe class JSONLogger: Logger
{
    ///
    this(const string fn, const LogLevel lv = LogLevel.all)
    {
        import std.datetime.systime : Clock;
        import std.datetime.timezone : SimpleTimeZone;

        super(lv);
        this.filename = fn;
        this.file_.open(this.filename, "w");
        auto now = Clock.currTime;
        auto offset = now.utcOffset;
        tz = new immutable SimpleTimeZone(offset);
    }

    ///
    this(File file, const LogLevel lv = LogLevel.all)
    {
        import std.datetime.systime : Clock;
        import std.datetime.timezone : SimpleTimeZone;

        super(lv);
        this.file_ = file;
        auto now = Clock.currTime;
        auto offset = now.utcOffset;
        tz = new immutable SimpleTimeZone(offset);
    }

    ///
    @property File file() nothrow
    {
        return this.file_;
    }

    override void writeLogMsg(ref LogEntry payload)
    {
        import std.conv : to;
        import std.exception : ifThrown;
        import std.json : JSONException, parseJSON;

        JSONValue log;
        log["timestamp"] = payload.timestamp.toOtherTZ(tz).toISOExtString;
        log["thread-id"] = () @trusted { return payload.threadId.to!string[4..$-1]; }();
        log["log-level"] = payload.logLevel.to!string;
        auto json = parseJSON(payload.msg).ifThrown!JSONException(JSONValue(["message": payload.msg]));
        log["payload"] = json;
        file.writeln(log);
        file.flush;
    }

    protected File file_;
    protected string filename;
    protected immutable TimeZone tz;
}

///
alias UserLogEntry = Tuple!(LogLevel, "level", string, "command");

auto userLog(Logger logger, UserLogEntry entry, JSONValue json, Config con)
{
    import medal.transition.core : substitute;

    import std.conv : to;
    import std.format : format;
    import std.json : JSONException, parseJSON;
    import std.process : executeShell, ProcessConfig = Config;
    import std.range : empty;

    if (entry.command.empty) return;

    auto cmd = entry.command.substitute(json);
    auto newEnv = con.evaledEnv;
    auto ls = executeShell(cmd, newEnv, ProcessConfig.newEnv, size_t.max, con.workdir);
    auto code = ls.status;
    auto output = ls.output;

    if (code == 0)
    {
        string msg;
        try
        {
            import std.conv : to;
            msg = parseJSON(output).to!string;
            logger.log(entry.level, msg);
        }
        catch(JSONException e)
        {
            logger.warning(JSONValue([
                "message": format!"Output of user command `%s` is not a valid JSON object"(entry.command),
                "log": output,
            ]).to!string);
        }
    }
    else
    {
        logger.warning(JSONValue([
            "message": format!"User command `%s` failed"(entry.command),
            "log": output,
        ]).to!string);
    }
}
