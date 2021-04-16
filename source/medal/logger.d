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

    override void writeLogMsg(ref LogEntry payload) @trusted
    {
        import std.conv : to;
        import std.exception : ifThrown;
        import std.json : JSONException, parseJSON;

        JSONValue log;
        log["timestamp"] = payload.timestamp.toOtherTZ(tz).toISOExtString;
        log["thread-id"] = payload.threadId.to!string[4..$-1];
        log["log-level"] = payload.logLevel.to!string;
        auto json = parseJSON(payload.msg).ifThrown!JSONException(JSONValue(["message": payload.msg]));
        if (".userlog" in json)
        {
            foreach(string k, v; json)
            {
                if (k == "log-level" || k == ".userlog")
                {
                    continue;
                }
                log[k] = v;
            }
        }
        else
        {
            log["payload"] = json;
        }
        file.writeln(log);
        file.flush;
    }

    protected File file_;
    protected string filename;
    protected immutable TimeZone tz;
}

///
void userLog(Logger logger, string entry, JSONValue vars, Config con)
{
    import medal.transition.core : substitute;

    import std.conv : to;
    import std.format : format;
    import std.json : JSONException, parseJSON;
    import std.process : executeShell, ProcessConfig = Config;
    import std.range : empty;

    void warningLog(Log)(string message, Log log)
    {
        JSONValue msg = [
            "message": JSONValue(message),
            "command": JSONValue(entry),
        ];
        static if (is(Log: string))
        {
            msg["log"] = log;
        }
        else static if (is(Log: JSONValue))
        {
            msg["parsed-log"] = log;
        }
        logger.warning(msg.to!string);
    }

    if (entry.empty) return;

    auto cmd = entry.substitute(vars);
    auto newEnv = con.evaledEnv;
    auto ls = executeShell(cmd, newEnv, ProcessConfig.newEnv, size_t.max, con.workdir);
    auto code = ls.status;
    auto output = ls.output;

    if (code == 0)
    {
        import std.conv : ConvException;

        JSONValue json;
        try
        {
            import std.json : parseJSON;
            json = parseJSON(output);
            LogLevel lv = LogLevel.info;
            if (auto l_ = "log-level" in json)
            {
                auto lvstr = l_.get!string;
                try
                {
                    lv = lvstr.to!LogLevel;
                }
                catch(ConvException e)
                {
                    warningLog(format!"Invalid log level `%s` in the output of log command"(lvstr), json);
                    return;
                }

                if (lv == LogLevel.fatal)
                {
                    warningLog(format!"Invalid log level `%s` in the output of log command"(lvstr), json);
                    return;
                }
            }

            if ("timestamp" in json)
            {
                warningLog("`timestamp` field is reserved by medal", json);
                return;
            }

            if ("thread-id" in json)
            {
                warningLog("`thread-id` field is reserved by medal", json);
                return;
            }

            if (".userlog" in json)
            {
                warningLog("`.userlog` field is reserved by medal", json);
                return;
            }

            json[".userlog"] = true;
            logger.log(lv, json.to!string);
        }
        catch(JSONException e)
        {
            warningLog("Output of log command is not a valid JSON object", output);
        }
    }
    else
    {
        logger.warning(JSONValue([
            "message": JSONValue("Log command failed"),
            "command": JSONValue(entry),
            "log": JSONValue(output),
            "return": JSONValue(code),
        ]).to!string);
    }
}
