import Family;
import Runner;
import haxe.io.Path;
import sys.FileSystem;

using StringTools;

typedef Opts = {
	var positional:Array<String>;
	var compiler:Null<String>;
	var haxe:Null<String>;
	var std:Null<String>;
	var hlExe:String;
	var cases:String;
	var expected:String;
	var divergences:Array<String>;
	var families:Array<String>;
	var exclude:Array<String>;
	var costs:Array<String>;
	var kinds:Array<String>;
	var oracles:Array<String>;
	var shard:Null<{k:Int, n:Int}>;
	var jobs:Int;
	var junit:Null<String>;
	var title:String;
	var verbose:Bool;
}

class Harness {
	static var libRoot:String;
	static var callerDir:String;

	static function main() {
		var args = Sys.args();
		libRoot = Sys.getCwd();
		callerDir = libRoot;
		if (Sys.getEnv("HAXELIB_RUN") == "1" && args.length > 0) callerDir = args.pop();

		if (args.length == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h") {
			usage();
			Sys.exit(args.length == 0 ? 2 : 0);
		}
		var command = args.shift();
		var o = parse(args);
		var code = try switch (command) {
			case "list": list(o);
			case "run": runCases(o, false);
			case "record": runCases(o, true);
			case "corpus": Corpus.run(o.positional, o.compiler, o.haxe, o.std, Path.join([libRoot, "tests"]), o.junit, loadDivergences(o), o.hlExe);
			case other:
				Sys.println('unknown command "$other"');
				usage();
				2;
		} catch (e:Dynamic) {
			Sys.println("error: " + Std.string(e));
			2;
		}
		Sys.exit(code);
	}

	static function usage() {
		Sys.println("haxelib run haxe-conformance <command> [options]

commands:
  list                       list the case families
  run                        run cases against a compiler
  record                     record Haxe's results under expected/
  corpus <suites>            run Haxe's own test suites (unit,misc,resolution,sourcemaps,
                             nullsafety,sys,threads,display; unit-hl only when named) with the compiler as `haxe`;
                             with --haxe, a suite fails only where that Haxe passes, and
                             --divergences lists \"suite/project\" entries that may fail

options:
  --compiler <path>          the compiler under test (for record: Haxe 4.3.7)
  --haxe <path>              compare with this Haxe live instead of the recordings
  --std <path>               HAXE_STD_PATH for every compile
  --hl-exe <path>            hl to run unit-hl with (default: hl on PATH)
  --cases <dir>              family root (default: this library's cases/)
  --expected <dir>           recordings (default: this library's expected/)
  --divergences <file>       JSON object: \"family/case\" -> reason; listed cases may differ;
                             repeat it to merge several files
  --family a,b               only these families (exact names)
  --exclude a,b              skip these families
  --cost quick,medium,slow   only families of these costs
  --kind <kinds>             only families of these kinds
  --oracle haxe,expected,self
  --shard k/n                run the k-th of n equal slices of the selected cases
  -j <n>                     parallel cases (default 4)
  --timeout <seconds>        per compile (default 120)
  --junit <file>             write a JUnit report
  --title <text>             name used in reports (default: haxe-conformance)
  -v                         print every case");
	}


	static function parse(args:Array<String>):Opts {
		var o:Opts = {
			positional: [], compiler: null, haxe: null, std: null, hlExe: "hl",
			cases: Path.join([libRoot, "cases"]), expected: Path.join([libRoot, "expected"]), divergences: [],
			families: [], exclude: [], costs: [], kinds: [], oracles: [], shard: null, jobs: 4, junit: null,
			title: "haxe-conformance", verbose: false
		};
		var i = 0;
		function value():String {
			if (i + 1 >= args.length) throw 'missing value after ${args[i]}';
			return args[++i];
		}
		function values():Array<String>
			return [for (s in value().split(",")) if (s.trim() != "") s.trim()];
		while (i < args.length) {
			switch (args[i]) {
				case "--compiler": o.compiler = resolve(value());
				case "--haxe": o.haxe = resolveExe(value());
				case "--std": o.std = resolve(value());
				case "--hl-exe": o.hlExe = resolveExe(value());
				case "--cases": o.cases = resolve(value());
				case "--expected": o.expected = resolve(value());
				case "--divergences": o.divergences.push(resolve(value()));
				case "--family": o.families = o.families.concat(values());
				case "--exclude": o.exclude = o.exclude.concat(values());
				case "--cost": o.costs = o.costs.concat(values());
				case "--kind": o.kinds = o.kinds.concat(values());
				case "--oracle": o.oracles = o.oracles.concat(values());
				case "--shard":
					var p = value().split("/");
					var k = Std.parseInt(p[0]), n = p.length == 2 ? Std.parseInt(p[1]) : null;
					if (k == null || n == null || n < 1 || k < 1 || k > n) throw "--shard expects k/n with 1 <= k <= n";
					o.shard = {k: k, n: n};
				case "-j" | "--jobs":
					var n = Std.parseInt(value());
					if (n == null || n < 1) throw "-j expects a positive number";
					o.jobs = n;
				case "--timeout":
					var t = Std.parseFloat(value());
					if (Math.isNaN(t) || t <= 0) throw "--timeout expects seconds";
					Exec.timeout = t;
				case "--junit": o.junit = resolve(value());
				case "--title": o.title = value();
				case "-v" | "--verbose": o.verbose = true;
				case s if (s.startsWith("-")): throw 'unknown option $s';
				case s: o.positional = o.positional.concat([for (p in s.split(",")) if (p.trim() != "") p.trim()]);
			}
			i++;
		}
		return o;
	}

	static function resolve(p:String):String
		return Path.normalize(Path.isAbsolute(p) ? p : Path.join([callerDir, p]));

	/** A bare name like `haxe` is looked up on PATH; anything with a directory is a path. */
	static function resolveExe(p:String):String
		return p.indexOf("/") < 0 && p.indexOf("\\") < 0 ? p : resolve(p);

	static function select(o:Opts):Array<Family> {
		if (!FileSystem.exists(o.cases)) throw 'no case directory at ${o.cases}';
		var all = Family.discover(o.cases);
		var names = [for (f in all) f.name];
		for (n in o.families.concat(o.exclude))
			if (names.indexOf(n) < 0) throw 'no family named "$n"';
		return all.filter(f -> (o.families.length == 0 || o.families.indexOf(f.name) >= 0)
			&& o.exclude.indexOf(f.name) < 0
			&& (o.costs.length == 0 || o.costs.indexOf(f.cost) >= 0)
			&& (o.kinds.length == 0 || o.kinds.indexOf(f.kind) >= 0)
			&& (o.oracles.length == 0 || o.oracles.indexOf(f.oracle) >= 0));
	}

	static function list(o:Opts):Int {
		var fs = select(o);
		var total = 0;
		for (f in fs) {
			Sys.println(StringTools.rpad(f.name, " ", 34) + StringTools.rpad(f.kind, " ", 15) + StringTools.rpad(f.oracle, " ", 10)
				+ StringTools.rpad(f.cost, " ", 8) + f.cases.length);
			total += f.cases.length;
		}
		Sys.println('${fs.length} families, $total cases');
		return 0;
	}

	static function loadDivergences(o:Opts):Map<String, String> {
		var divergences = new Map<String, String>();
		for (file in o.divergences) {
			var json:Dynamic = haxe.Json.parse(sys.io.File.getContent(file));
			for (k in Reflect.fields(json)) divergences.set(k, Reflect.field(json, k));
		}
		return divergences;
	}

	static function runCases(o:Opts, record:Bool):Int {
		if (o.compiler == null) throw "--compiler is required";
		if (!FileSystem.exists(o.compiler)) throw 'compiler not found: ${o.compiler}';
		var families = select(o);
		if (record) families = families.filter(f -> (f.oracle : String) == Oracle.Haxe);
		var cases:Array<Case> = [];
		for (f in families) cases = cases.concat(f.cases);
		if (o.shard != null && !record) cases = [for (i in 0...cases.length) if (i % o.shard.n == o.shard.k - 1) cases[i]];
		if (cases.length == 0) {
			Sys.println("no cases selected");
			return 1;
		}

		var divergences = loadDivergences(o);

		var scratch = Path.join([Exec.tempRoot(), "haxe-conformance", Std.string(Std.random(0x7FFFFFF))]);
		Exec.mkdirs(scratch);
		Sys.println('compiler : ${o.compiler}');
		Sys.println('compare  : ' + (record ? "recording" : o.haxe != null ? 'live ${o.haxe}' : 'recordings in ${o.expected}'));
		if (o.std != null) Sys.println('std      : ${o.std}');
		Sys.println('cases    : ${cases.length} in ${families.length} families' + (o.shard != null ? ' (shard ${o.shard.k}/${o.shard.n})' : ""));
		Sys.println("");

		var t0 = Sys.time();
		var results = Runner.run(cases, {
			compiler: o.compiler, haxe: o.haxe, std: o.std, expectedDir: o.expected, divergences: divergences,
			jobs: o.jobs, scratch: scratch, record: record, verbose: o.verbose
		});
		var seconds = Sys.time() - t0;
		try Exec.removeTree(scratch) catch (_:Dynamic) {}

		if (record) {
			var rec = Runner.recordings(results);
			for (f in families) Expectations.save(o.expected, f, rec.exists(f.name) ? rec.get(f.name) : new Map());
			Sys.println('recorded ${results.length} cases in ${families.length} families to ${o.expected}');
			return 0;
		}
		Report.print(results, seconds);
		if (o.junit != null) Report.junit(o.junit, o.title, results);
		Report.stepSummary(o.title, results, seconds);
		return Report.failed(results) ? 1 : 0;
	}
}
