ResourceWriter = require "./ResourceWriter"
LatexRunner = require "./LatexRunner"
OutputFileFinder = require "./OutputFileFinder"
OutputCacheManager = require "./OutputCacheManager"
Settings = require("settings-sharelatex")
Path = require "path"
logger = require "logger-sharelatex"
Metrics = require "./Metrics"
child_process = require "child_process"
DraftModeManager = require "./DraftModeManager"
fs = require("fs")
os = require("os")

commandRunner = Settings.clsi?.commandRunner or "./CommandRunner"
logger.info commandRunner:commandRunner, "selecting command runner for clsi"
CommandRunner = require(commandRunner)

getCompileName = (project_id, user_id) ->
	if user_id? then "#{project_id}-#{user_id}" else project_id

getCompileDir = (project_id, user_id) ->
	Path.join(Settings.path.compilesDir, getCompileName(project_id, user_id))

module.exports = CompileManager =
	doCompile: (request, callback = (error, outputFiles) ->) ->
		compileDir = getCompileDir(request.project_id, request.user_id)

		timer = new Metrics.Timer("write-to-disk")
		logger.log project_id: request.project_id, user_id: request.user_id, "starting compile"
		ResourceWriter.syncResourcesToDisk request.project_id, request.resources, compileDir, (error) ->
			if error?
				logger.err err:error, project_id: request.project_id, user_id: request.user_id, "error writing resources to disk"
				return callback(error) 
			logger.log project_id: request.project_id, user_id: request.user_id, time_taken: Date.now() - timer.start, "written files to disk"
			timer.done()
			
			injectDraftModeIfRequired = (callback) ->
				if request.draft
					DraftModeManager.injectDraftMode Path.join(compileDir, request.rootResourcePath), callback
				else
					callback()
			
			injectDraftModeIfRequired (error) ->
				return callback(error) if error?
				timer = new Metrics.Timer("run-compile")
				# find the image tag to log it as a metric, e.g. 2015.1 (convert . to - for graphite)
				tag = request.imageName?.match(/:(.*)/)?[1]?.replace(/\./g,'-') or "default"
				tag = "other" if not request.project_id.match(/^[0-9a-f]{24}$/) # exclude smoke test
				Metrics.inc("compiles")
				Metrics.inc("compiles-with-image.#{tag}")
				compileName = getCompileName(request.project_id, request.user_id)
				LatexRunner.runLatex compileName, {
					directory: compileDir
					mainFile:  request.rootResourcePath
					compiler:  request.compiler
					timeout:   request.timeout
					image:     request.imageName
				}, (error, output, stats, timings) ->
					return callback(error) if error?
					Metrics.inc("compiles-succeeded")
					for metric_key, metric_value of stats or {}
						Metrics.count(metric_key, metric_value)
					for metric_key, metric_value of timings or {}
						Metrics.timing(metric_key, metric_value)
					loadavg = os.loadavg?()
					Metrics.gauge("load-avg", loadavg[0]) if loadavg?
					ts = timer.done()
					logger.log {project_id: request.project_id, user_id: request.user_id, time_taken: ts, stats:stats, timings:timings, loadavg:loadavg}, "done compile"
					if stats?["latex-runs"] > 0
						Metrics.timing("run-compile-per-pass", ts / stats["latex-runs"])
					if stats?["latex-runs"] > 0 and timings?["cpu-time"] > 0
						Metrics.timing("run-compile-cpu-time-per-pass", timings["cpu-time"] / stats["latex-runs"])

					OutputFileFinder.findOutputFiles request.resources, compileDir, (error, outputFiles) ->
						return callback(error) if error?
						OutputCacheManager.saveOutputFiles outputFiles, compileDir,  (error, newOutputFiles) ->
							callback null, newOutputFiles
	
	clearProject: (project_id, _callback = (error) ->) ->
		callback = (error) ->
			_callback(error)
			_callback = () ->

		compileDir = Path.join(Settings.path.compilesDir, project_id)

		CompileManager._checkDirectory compileDir, (err, exists) ->
			return callback(err) if err?
			return callback() if not exists # skip removal if no directory present

			proc = child_process.spawn "rm", ["-r", compileDir]

			proc.on "error", callback

			stderr = ""
			proc.stderr.on "data", (chunk) -> stderr += chunk.toString()

			proc.on "close", (code) ->
				if code == 0
					return callback(null)
				else
					return callback(new Error("rm -r #{compileDir} failed: #{stderr}"))

	_checkDirectory: (compileDir, callback = (error, exists) ->) ->
		fs.lstat compileDir, (err, stats) ->
			if err?.code is 'ENOENT'
				return callback(null, false) #  directory does not exist
			else if err?
				logger.err {dir: compileDir, err:err}, "error on stat of project directory for removal"
				return callback(err)
			else if not stats?.isDirectory()
				logger.err {dir: compileDir, stats:stats}, "bad project directory for removal"
				return callback new Error("project directory is not directory")
			else
				callback(null, true) # directory exists

	syncFromCode: (project_id, user_id, file_name, line, column, callback = (error, pdfPositions) ->) ->
		# If LaTeX was run in a virtual environment, the file path that synctex expects
		# might not match the file path on the host. The .synctex.gz file however, will be accessed
		# wherever it is on the host.
		compileName = getCompileName(project_id, user_id)
		base_dir = Settings.path.synctexBaseDir(compileName)
		file_path = base_dir + "/" + file_name
		compileDir = getCompileDir(project_id, user_id)
		synctex_path = Path.join(compileDir, "output.pdf")
		CompileManager._runSynctex ["code", synctex_path, file_path, line, column], (error, stdout) ->
			return callback(error) if error?
			logger.log project_id: project_id, user_id:user_id, file_name: file_name, line: line, column: column, stdout: stdout, "synctex code output"
			callback null, CompileManager._parseSynctexFromCodeOutput(stdout)

	syncFromPdf: (project_id, user_id, page, h, v, callback = (error, filePositions) ->) ->
		compileName = getCompileName(project_id, user_id)
		base_dir = Settings.path.synctexBaseDir(compileName)
		compileDir = getCompileDir(project_id, user_id)
		synctex_path = Path.join(compileDir, "output.pdf")
		CompileManager._runSynctex ["pdf", synctex_path, page, h, v], (error, stdout) ->
			return callback(error) if error?
			logger.log project_id: project_id, user_id:user_id, page: page, h: h, v:v, stdout: stdout, "synctex pdf output"
			callback null, CompileManager._parseSynctexFromPdfOutput(stdout, base_dir)

	_runSynctex: (args, callback = (error, stdout) ->) ->
		bin_path = Path.resolve(__dirname + "/../../bin/synctex")
		seconds = 1000
		child_process.execFile bin_path, args, timeout: 10 * seconds, (error, stdout, stderr) ->
			if error?
				logger.err err:error, args:args, "error running synctex"
				return callback(error)
			callback(null, stdout)

	_parseSynctexFromCodeOutput: (output) ->
		results = []
		for line in output.split("\n")
			[node, page, h, v, width, height] = line.split("\t")
			if node == "NODE"
				results.push {
					page:   parseInt(page, 10)
					h:      parseFloat(h)
					v:      parseFloat(v)
					height: parseFloat(height)
					width:  parseFloat(width)
				}
		return results

	_parseSynctexFromPdfOutput: (output, base_dir) ->
		results = []
		for line in output.split("\n")
			[node, file_path, line, column] = line.split("\t")
			if node == "NODE"
				file = file_path.slice(base_dir.length + 1)
				results.push {
					file: file
					line: parseInt(line, 10)
					column: parseInt(column, 10)
				}
		return results

	wordcount: (project_id, user_id, file_name, image, callback = (error, pdfPositions) ->) ->
		logger.log project_id:project_id, user_id:user_id, file_name:file_name, image:image, "running wordcount"
		file_path = "$COMPILE_DIR/" + file_name
		command = [ "texcount", '-inc', file_path, "-out=" + file_path + ".wc"]
		directory = getCompileDir(project_id, user_id)
		timeout = 10 * 1000
		compileName = getCompileName(project_id, user_id)

		CommandRunner.run compileName, command, directory, image, timeout, (error) ->
			return callback(error) if error?
			try
				stdout = fs.readFileSync(directory + "/" + file_name + ".wc", "utf-8")
			catch err
				logger.err err:err, command:command, directory:directory, project_id:project_id, user_id:user_id, "error reading word count output"
				return callback(err)
			callback null, CompileManager._parseWordcountFromOutput(stdout)

	_parseWordcountFromOutput: (output) ->
		results = {
			encode: ""
			textWords: 0
			headWords: 0
			outside: 0
			headers: 0
			elements: 0
			mathInline: 0
			mathDisplay: 0
		}
		for line in output.split("\n")
			[data, info] = line.split(":")
			if data.indexOf("Encoding") > -1
				results['encode'] = info.trim()
			if data.indexOf("in text") > -1
				results['textWords'] = parseInt(info, 10)
			if data.indexOf("in head") > -1
				results['headWords'] = parseInt(info, 10)
			if data.indexOf("outside") > -1
				results['outside'] = parseInt(info, 10)
			if data.indexOf("of head") > -1
				results['headers'] = parseInt(info, 10)
			if data.indexOf("Number of floats/tables/figures") > -1
				results['elements'] = parseInt(info, 10)
			if data.indexOf("Number of math inlines") > -1
				results['mathInline'] = parseInt(info, 10)
			if data.indexOf("Number of math displayed") > -1
				results['mathDisplay'] = parseInt(info, 10)
		return results
