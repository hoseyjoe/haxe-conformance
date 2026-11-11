import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

typedef SuiteResult = {
	var name:String;
	var ok:Bool;
	var seconds:Float;
	var note:String;
}

/** Haxe's own test suites under tests/, run the way tests/runci/targets/Macro.hx runs them. **/
class Corpus {
	static final all = ["unit", "misc", "resolution", "sourcemaps", "nullsafety", "sys", "threads"];

	/**
		Runs each suite with the compiler installed as `haxe`. With a reference Haxe, a suite that fails
		is run with it too, and only what fails with the compiler alone counts: for misc, the projects
		its summary lists. Listed divergences, keyed `suite/project`, may fail.
	**/
	public static function run(suites:Array<String>, compiler:Null<String>, haxe:Null<String>, std:Null<String>,
			testsDir:String, junit:Null<String>, divergences:Map<String, String>, hlExe:String = "hl"):Int {
		if (compiler == null) throw "--compiler is required";
		if (!FileSystem.exists(compiler)) throw 'compiler not found: $compiler';
		if (suites.length == 0) suites = all;
		for (s in suites)
			if (all.indexOf(s) < 0 && s != "display" && s != "unit-hl") throw 'unknown suite "$s"';

		var shim = Path.join([Exec.tempRoot(), "haxe-conformance-shim-" + Std.random(0x7FFFFFF)]);
		Exec.mkdirs(shim);
		var exe = Path.join([shim, Exec.isWindows ? "haxe.exe" : "haxe"]);
		File.copy(compiler, exe);
		if (!Exec.isWindows) Sys.command("chmod", ["+x", exe]);
		if (std != null) Sys.putEnv("HAXE_STD_PATH", std);
		var sep = Exec.isWindows ? ";" : ":";
		var basePath = Sys.getEnv("PATH");
		var testedPath = shim + sep + basePath;
		// A Haxe install keeps its libraries beside the executable, so the reference runs from its own directory.
		var referenceDir = haxe == null ? "" : Path.directory(haxe);
		var referencePath = referenceDir == "" ? basePath : FileSystem.fullPath(referenceDir) + sep + basePath;
		if (Exec.timeout < 3600) Exec.timeout = 3600;

		var system = ["-D", Sys.systemName()];
		var steps:Array<{name:String, dir:String, args:Array<String>}> = [];
		for (s in suites)
			switch (s) {
				case "unit": steps.push({name: "unit", dir: "unit", args: ["compile-macro.hxml"].concat(system)});
				case "misc": steps.push({name: "misc", dir: "misc", args: ["compile.hxml"]});
				case "resolution": steps.push({name: "resolution", dir: "misc/resolution", args: ["run.hxml"]});
				case "sourcemaps": steps.push({name: "sourcemaps", dir: "sourcemaps", args: ["run.hxml"]});
				case "nullsafety":
					steps.push({name: "nullsafety", dir: "nullsafety", args: ["test.hxml"]});
					steps.push({name: "nullsafety-js-es6", dir: "nullsafety", args: ["test-js-es6.hxml"]});
				case "sys":
					Sys.putEnv("EXISTS", "1");
					steps.push({name: "sys", dir: "sys", args: ["compile-macro.hxml"].concat(system)});
				case "threads": steps.push({name: "threads", dir: "threads", args: ["build.hxml", "--interp"]});
				case "display": steps.push({name: "display", dir: "display", args: ["build.hxml"]});
				case "unit-hl": steps.push({name: "unit-hl", dir: "unit", args: []});
			}

		var results:Array<SuiteResult> = [];
		var known:Array<String> = [];
		var stale:Array<String> = [];
		for (step in steps) {
			if (step.name == "unit-hl") {
				results.push(UnitHl.run(compiler, haxe, std, hlExe, testsDir));
				continue;
			}
			Sys.println('=== ${step.name}: haxe ${step.args.join(" ")}  (tests/${step.dir})');
			var dir = Path.join([testsDir, step.dir]);
			var t0 = Sys.time();
			var got = Exec.run("haxe", step.args, ["PATH" => testedPath], dir);
			Sys.println(got.output.trim());
			var failed = [for (p in failedProjects(got.output)) step.name + "/" + p];
			for (k in divergences.keys())
				if (k.startsWith(step.name + "/") && failed.indexOf(k) < 0) stale.push(k);
			var unexplained = [for (p in failed) if (!divergences.exists(p)) p];
			for (p in failed) if (divergences.exists(p)) known.push(p);
			var ok = got.code == 0 || (failed.length > 0 && unexplained.length == 0);
			var note = ok ? "" : 'exit ${got.code}';
			if (!ok && haxe != null) {
				var want = Exec.run("haxe", step.args, ["PATH" => referencePath], dir);
				var reference = [for (p in failedProjects(want.output)) step.name + "/" + p];
				if (want.code == 0) {
					note = "fails only with the compiler";
				} else if (failed.length == 0 && reference.length == 0) {
					ok = true;
					note = "fails with Haxe too";
				} else {
					unexplained = [for (p in unexplained) if (reference.indexOf(p) < 0) p];
					ok = unexplained.length == 0 && failed.length > 0;
					note = ok ? "fails where Haxe does" : "fails only with the compiler: " + unexplained.join(", ");
				}
			}
			results.push({name: step.name, ok: ok, seconds: Sys.time() - t0, note: note});
			Sys.println('=== ${step.name}: ' + (ok ? "PASS" : "FAIL") + (note != "" ? '  ($note)' : ""));
			Sys.println("");
		}
		try Exec.removeTree(shim) catch (_:Dynamic) {}

		var failures = 0;
		for (r in results) {
			Sys.println('  ' + (r.ok ? "PASS" : "FAIL") + '  ${r.name}  (${Math.round(r.seconds)}s)' + (r.note != "" ? '  ${r.note}' : ""));
			if (!r.ok) failures++;
		}
		if (known.length > 0) {
			Sys.println("");
			Sys.println("known divergences:");
			for (k in known) Sys.println('  $k  -  ${divergences.get(k)}');
		}
		for (k in stale) Sys.println('  STALE  $k  (passes, but is still listed in the divergences file)');
		var bad = failures + stale.length;
		Sys.println(bad == 0 ? "RESULT: PASS" : "RESULT: FAIL");
		if (junit != null) {
			var b = new StringBuf();
			b.add('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="corpus" tests="${results.length}" failures="$failures">\n');
			b.add('  <testsuite name="corpus" tests="${results.length}" failures="$failures">\n');
			for (r in results) {
				b.add('    <testcase classname="corpus" name="${r.name}" time="${Math.round(r.seconds)}"');
				b.add(r.ok ? "/>\n" : '>\n      <failure message="${StringTools.htmlEscape(r.note, true)}"/>\n    </testcase>\n');
			}
			b.add("  </testsuite>\n</testsuites>\n");
			File.saveContent(junit, b.toString());
		}
		return bad == 0 ? 0 : 1;
	}

	/** The projects a misc-style runner lists after "SUMMARY:", as paths relative to its directory. **/
	static function failedProjects(output:String):Array<String> {
		var i = output.indexOf("SUMMARY:");
		if (i < 0) return [];
		var out = [];
		for (line in output.substr(i).replace("\r", "").split("\n"))
			if (~/^projects\/\S+\.hxml$/.match(line) && out.indexOf(line) < 0) out.push(line);
		return out;
	}
}
