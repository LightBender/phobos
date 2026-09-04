/**
Measure template instantiations and generated-code size for a Phobos module.

Compares two git refs by compiling a driver against each tree via git worktrees,
then reports object size, DMD `-vtemplates=list-instances` counts, and optional
dumpbin / llvm-nm / nm symbol counts.

Usage (from the phobos repository root):

    rdmd tools/measure_templates.d --old=HEAD --new=HEAD --module=std.utf
    rdmd tools/measure_templates.d --old=master --new=HEAD --driver=tools/measure_utf_driver.d --report=report.md

Do not rewrite Phobos sources through PowerShell; this tool copies trees with
git worktrees.
*/
module measure_templates;

import std.algorithm;
import std.array;
import std.datetime.systime : Clock;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.stdio;
import std.string;

int main(string[] args)
{
    Options opt;
    if (!parseArgs(args, opt))
        return 1;

    const repoRoot = findRepoRoot();
    const workRoot = opt.workDir.length ? opt.workDir
        : buildPath(tempDir, "phobos-measure-" ~ randomSuffix());
    mkdirRecurse(workRoot);
    scope (exit)
        if (!opt.keepWork)
            rmdirRecurseSafe(workRoot);

    const oldTree = buildPath(workRoot, "old");
    const newTree = buildPath(workRoot, "new");
    const outDir = buildPath(workRoot, "out");
    mkdirRecurse(outDir);

    writeln("repo: ", repoRoot);
    writeln("old:  ", opt.oldRef);
    writeln("new:  ", opt.newRef);
    writeln("work: ", workRoot);

    addWorktree(repoRoot, oldTree, opt.oldRef);
    addWorktree(repoRoot, newTree, opt.newRef);
    scope (exit)
    {
        removeWorktree(repoRoot, oldTree);
        removeWorktree(repoRoot, newTree);
    }

    const driverSrc = opt.driver.length
        ? absolutePath(opt.driver)
        : writeDefaultDriver(outDir, opt.mod);
    const compiler = findCompiler(opt.compiler);

    auto oldRes = compileOne(compiler, oldTree, driverSrc, buildPath(outDir, "old"), opt);
    auto newRes = compileOne(compiler, newTree, driverSrc, buildPath(outDir, "new"), opt);

    const report = renderReport(opt, oldRes, newRes, driverSrc);
    writeln();
    writeln(report);

    if (opt.report.length)
    {
        const reportPath = absolutePath(opt.report);
        mkdirRecurse(dirName(reportPath));
        std.file.write(reportPath, report);
        writeln("wrote ", reportPath);
    }
    return 0;
}

struct Options
{
    string oldRef = "HEAD";
    string newRef = "HEAD";
    string mod = "std.utf";
    string driver;
    string compiler;
    string workDir;
    string report;
    string[] extraFlags;
    string[] symbols = [
        "stride", "strideBack", "isValidUTF", "validate",
        "codeLength", "decode", "byUTF", "Result"
    ];
    bool keepWork;
}

struct CompileResult
{
    string label;
    string objPath;
    ulong objSize;
    string vtemplatesPath;
    TemplateStats templates;
    SymbolStats symbols;
}

struct TemplateStats
{
    ulong lines;
    ulong named;
    ulong sites;
    ulong[string] namedBySymbol;
}

struct SymbolStats
{
    bool available;
    string tool;
    ulong total;
    ulong[string] byNeedle;
}

bool parseArgs(string[] args, ref Options opt)
{
    foreach (arg; args[1 .. $])
    {
        if (arg == "-h" || arg == "--help")
        {
            printHelp();
            return false;
        }
        else if (arg.startsWith("--old="))
            opt.oldRef = arg["--old=".length .. $];
        else if (arg.startsWith("--new="))
            opt.newRef = arg["--new=".length .. $];
        else if (arg.startsWith("--module="))
            opt.mod = arg["--module=".length .. $];
        else if (arg.startsWith("--driver="))
            opt.driver = arg["--driver=".length .. $];
        else if (arg.startsWith("--compiler="))
            opt.compiler = arg["--compiler=".length .. $];
        else if (arg.startsWith("--work-dir="))
            opt.workDir = arg["--work-dir=".length .. $];
        else if (arg.startsWith("--report="))
            opt.report = arg["--report=".length .. $];
        else if (arg.startsWith("--symbol="))
            opt.symbols ~= arg["--symbol=".length .. $];
        else if (arg.startsWith("--flag="))
            opt.extraFlags ~= arg["--flag=".length .. $];
        else if (arg == "--keep-work")
            opt.keepWork = true;
        else
        {
            stderr.writeln("unknown argument: ", arg);
            printHelp();
            return false;
        }
    }
    return true;
}

void printHelp()
{
    writeln(
`measure_templates — compare template instantiations and object size

Options:
  --old=REF           git ref for the baseline (default: HEAD)
  --new=REF           git ref for the candidate (default: HEAD)
  --module=NAME       D module imported by the default driver (default: std.utf)
  --driver=FILE       custom driver .d file
  --compiler=PATH     dmd/ldc2 executable
  --work-dir=DIR      keep/reuse a work directory
  --report=FILE       write markdown report to FILE
  --symbol=NAME       extra symbol needle for dumpbin/nm (repeatable)
  --flag=FLAG         extra compiler flag (repeatable)
  --keep-work         do not delete the work directory
`);
}

string findRepoRoot()
{
    auto p = execute(["git", "rev-parse", "--show-toplevel"]);
    enforce(p.status == 0, "git rev-parse failed: " ~ p.output);
    return p.output.strip;
}

string findCompiler(string explicitPath)
{
    if (explicitPath.length)
        return explicitPath;

    foreach (c; ["dmd", "ldc2"])
    {
        auto r = executeShell("where " ~ c);
        if (r.status == 0)
        {
            auto first = r.output.splitLines.front.strip;
            if (first.length)
                return first;
        }
    }
    enforce(false, "could not find dmd on PATH");
    assert(false);
}

void addWorktree(string repo, string path, string gitRef)
{
    if (exists(path))
        rmdirRecurseSafe(path);
    auto r = execute(["git", "-C", repo, "worktree", "add", "--detach", path, gitRef]);
    enforce(r.status == 0, "git worktree add failed:\n" ~ r.output);
}

void removeWorktree(string repo, string path)
{
    execute(["git", "-C", repo, "worktree", "remove", "--force", path]);
    if (exists(path))
        rmdirRecurseSafe(path);
}

void rmdirRecurseSafe(string path)
{
    if (!exists(path))
        return;
    try
        rmdirRecurse(path);
    catch (Exception)
    {
        version (Windows)
            execute(["cmd", "/c", "rmdir", "/s", "/q", path]);
    }
}

string randomSuffix()
{
    return Clock.currTime.toISOString.replace(":", "").replace(".", "");
}

string writeDefaultDriver(string outDir, string mod)
{
    const path = buildPath(outDir, "driver.d");
    std.file.write(path, "module driver;\nimport " ~ mod ~ ";\nvoid main() {}\n");
    return path;
}

CompileResult compileOne(string compiler, string tree, string driver, string prefix, Options opt)
{
    CompileResult res;
    res.label = prefix.baseName;
    res.objPath = prefix ~ ".obj";
    res.vtemplatesPath = prefix ~ ".vtemplates.txt";

    string[] cmd = [
        compiler, "-c",
        "-vtemplates=list-instances",
        "-I" ~ tree,
        "-of" ~ res.objPath,
        driver,
    ];
    cmd ~= opt.extraFlags;

    auto r = execute(cmd, null, Config.none, size_t.max, tree);
    std.file.write(res.vtemplatesPath, r.output);
    if (r.status != 0)
    {
        stderr.writeln(r.output);
        enforce(false, "compile failed (" ~ res.label ~ ")");
    }

    if (exists(res.objPath))
        res.objSize = getSize(res.objPath);
    res.templates = parseVtemplates(r.output);
    res.symbols = collectSymbols(res.objPath, opt.symbols);
    return res;
}

TemplateStats parseVtemplates(string output)
{
    TemplateStats stats;
    foreach (line; output.splitLines)
    {
        if (!line.length)
            continue;
        stats.lines++;
        const indented = line.startsWith(" ") || line.startsWith("\t");
        if (!indented && line.canFind("!"))
        {
            auto current = templateName(line);
            stats.named++;
            stats.sites++;
            if (current.length)
                stats.namedBySymbol[current] = stats.namedBySymbol.get(current, 0) + 1;
        }
        else if (indented)
        {
            stats.sites++;
        }
    }
    return stats;
}

string templateName(string line)
{
    auto bang = line.lastIndexOf('!');
    if (bang <= 0)
        return null;
    auto head = line[0 .. bang];
    auto dot = head.lastIndexOf('.');
    return dot >= 0 ? head[dot + 1 .. $] : head;
}

SymbolStats collectSymbols(string objPath, string[] needles)
{
    SymbolStats stats;
    if (!exists(objPath))
        return stats;

    string[] cmd;
    string tool;
    version (Windows)
    {
        auto dump = executeShell("where dumpbin");
        if (dump.status == 0)
        {
            tool = "dumpbin";
            cmd = [dump.output.splitLines.front.strip, "/SYMBOLS", objPath];
        }
    }
    if (!cmd.length)
    {
        foreach (cand; ["llvm-nm", "nm"])
        {
            auto w = executeShell("where " ~ cand);
            if (w.status == 0)
            {
                tool = cand;
                cmd = [w.output.splitLines.front.strip, objPath];
                break;
            }
        }
    }
    if (!cmd.length)
        return stats;

    auto r = execute(cmd);
    if (r.status != 0)
        return stats;

    stats.available = true;
    stats.tool = tool;
    auto lines = r.output.splitLines;
    stats.total = lines.length;
    foreach (n; needles)
        stats.byNeedle[n] = lines.filter!(l => l.canFind(n)).count;
    return stats;
}

string renderReport(Options opt, CompileResult oldRes, CompileResult newRes, string driverSrc)
{
    auto app = appender!string();
    app.put("# Template instantiation / generated-code report\n\n");
    app.put("Measured with `tools/measure_templates.d`.\n\n");
    app.put("- Module: `" ~ opt.mod ~ "`\n");
    app.put("- Baseline (`--old`): `" ~ opt.oldRef ~ "`\n");
    app.put("- Candidate (`--new`): `" ~ opt.newRef ~ "`\n");
    app.put("- Driver: `" ~ driverSrc ~ "`\n\n");

    app.put("## Object size\n\n");
    app.put("| | bytes |\n|---|---:|\n");
    app.put(format("| old | %s |\n", oldRes.objSize));
    app.put(format("| new | %s |\n", newRes.objSize));
    app.put(format("| delta | %+d |\n\n", cast(long) newRes.objSize - cast(long) oldRes.objSize));

    app.put("## `-vtemplates=list-instances`\n\n");
    app.put("| | old | new | delta |\n|---|---:|---:|---:|\n");
    app.put(row("log lines", oldRes.templates.lines, newRes.templates.lines));
    app.put(row("named instantiations", oldRes.templates.named, newRes.templates.named));
    app.put(row("instance sites", oldRes.templates.sites, newRes.templates.sites));
    app.put("\nNamed instantiations are unique `name!args` lines. Instance sites include indented locations under `-vtemplates=list-instances`.\n\n");

    auto names = (oldRes.templates.namedBySymbol.keys ~ newRes.templates.namedBySymbol.keys)
        .sort.uniq.array;
    if (names.length)
    {
        app.put("### Distinct instantiations by name\n\n");
        app.put("| name | old | new | delta |\n|---|---:|---:|---:|\n");
        foreach (n; names)
        {
            const o = oldRes.templates.namedBySymbol.get(n, 0);
            const nw = newRes.templates.namedBySymbol.get(n, 0);
            if (o || nw)
                app.put(row("`" ~ n ~ "`", o, nw));
        }
        app.put("\n");
    }

    if (oldRes.symbols.available || newRes.symbols.available)
    {
        const tool = newRes.symbols.tool.length ? newRes.symbols.tool : oldRes.symbols.tool;
        app.put("## Symbols (`" ~ tool ~ "`)\n\n");
        app.put("| | old | new | delta |\n|---|---:|---:|---:|\n");
        app.put(row("total lines", oldRes.symbols.total, newRes.symbols.total));
        auto needles = (oldRes.symbols.byNeedle.keys ~ newRes.symbols.byNeedle.keys)
            .sort.uniq.array;
        foreach (n; needles)
            app.put(row("`" ~ n ~ "`", oldRes.symbols.byNeedle.get(n, 0), newRes.symbols.byNeedle.get(n, 0)));
        app.put("\n");
    }

    app.put("## Notes\n\n");
    app.put("- Object size is the better bloat signal; `-vtemplates` counts can move independently.\n");
    app.put("- Decode / `decodeImpl` were not modified in this change.\n");
    app.put("- A tiny trampoline around a shared implementation is preferred over folding a `static if` into a large body.\n");
    return app.data;
}

string row(string name, ulong oldV, ulong newV)
{
    return format("| %s | %s | %s | %+d |\n", name, oldV, newV, cast(long) newV - cast(long) oldV);
}
