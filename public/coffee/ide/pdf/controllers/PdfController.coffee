define [
	"base"
	"ace/ace"
	"ide/human-readable-logs/HumanReadableLogs"
	"libs/bib-log-parser"
	"services/log-hints-feedback"
], (App, Ace, HumanReadableLogs, BibLogParser) ->
	AUTO_COMPILE_MAX_WAIT = 5000
	# We add a 1 second debounce to sending user changes to server if they aren't
	# collaborating with anyone. This needs to be higher than that, and allow for
	# client to server latency, otherwise we compile before the op reaches the server
	# and then again on ack.
	AUTO_COMPILE_DEBOUNCE = 2000

	App.controller "PdfController", ($scope, $http, ide, $modal, synctex, event_tracking, logHintsFeedback, localStorage) ->
		# enable per-user containers by default
		perUserCompile = true
		autoCompile = true

		# pdf.view = uncompiled | pdf | errors
		$scope.pdf.view = if $scope?.pdf?.url then 'pdf' else 'uncompiled'
		$scope.shouldShowLogs = false
		$scope.wikiEnabled = window.wikiEnabled;

		# view logic to check whether the files dropdown should "drop up" or "drop down"
		$scope.shouldDropUp = false

		logsContainerEl	= document.querySelector ".pdf-logs"
		filesDropdownEl	= logsContainerEl?.querySelector ".files-dropdown"

		# get the top coordinate of the files dropdown as a ratio (to the logs container height)
		# logs container supports scrollable content, so it's possible that ratio > 1.
		getFilesDropdownTopCoordAsRatio = () ->
			 filesDropdownEl?.getBoundingClientRect().top / logsContainerEl?.getBoundingClientRect().height

		$scope.$watch "shouldShowLogs", (shouldShow) ->
			if shouldShow
				$scope.$applyAsync () ->
					$scope.shouldDropUp = getFilesDropdownTopCoordAsRatio() > 0.65

		# log hints tracking
		$scope.logHintsNegFeedbackValues = logHintsFeedback.feedbackOpts

		$scope.trackLogHintsLearnMore = () ->
			event_tracking.sendMB "logs-hints-learn-more"

		trackLogHintsFeedback = (isPositive, hintId) ->
			event_tracking.send "log-hints", (if isPositive then "feedback-positive" else "feedback-negative"), hintId
			event_tracking.sendMB (if isPositive then "log-hints-feedback-positive" else "log-hints-feedback-negative"), { hintId }

		$scope.trackLogHintsNegFeedbackDetails = (hintId, feedbackOpt, feedbackOtherVal) ->
			logHintsFeedback.submitFeedback hintId, feedbackOpt, feedbackOtherVal

		$scope.trackLogHintsPositiveFeedback = (hintId) -> trackLogHintsFeedback true, hintId
		$scope.trackLogHintsNegativeFeedback = (hintId) -> trackLogHintsFeedback false, hintId

		if ace.require("ace/lib/useragent").isMac
			$scope.modifierKey = "Cmd"
		else
			$scope.modifierKey = "Ctrl"

		# utility for making a query string from a hash, could use jquery $.param
		createQueryString = (args) ->
			qs_args = ("#{k}=#{v}" for k, v of args)
			if qs_args.length then "?" + qs_args.join("&") else ""

		$scope.stripHTMLFromString = (htmlStr) ->
   			tmp = document.createElement("DIV")
   			tmp.innerHTML = htmlStr
   			return tmp.textContent || tmp.innerText || ""

		$scope.$on "project:joined", () ->
			return if !autoCompile
			autoCompile = false
			$scope.recompile(isAutoCompileOnLoad: true)
			$scope.hasPremiumCompile = $scope.project.features.compileGroup == "priority"

		$scope.$on "pdf:error:display", () ->
			$scope.pdf.view = 'errors'
			$scope.pdf.renderingError = true

		autoCompileInterval = null
		autoCompileIfReady = () ->
			if $scope.pdf.compiling
				return

			# Only checking linting if syntaxValidation is on and visible to the user
			autoCompileLintingError = ide.$scope.hasLintingError and ide.$scope.settings.syntaxValidation
			if $scope.autoCompileLintingError != autoCompileLintingError
				$scope.$apply () ->
					$scope.autoCompileLintingError = autoCompileLintingError
					# We've likely been waiting a while until the user fixed the linting, but we
					# don't want to compile as soon as it is fixed, so reset the timeout.
					$scope.startedTryingAutoCompileAt = Date.now()
					$scope.docLastChangedAt = Date.now()
			if autoCompileLintingError
				return

			# If there's a longish compile, don't compile immediately after if user is still typing
			startedTryingAt = Math.max($scope.startedTryingAutoCompileAt, $scope.lastFinishedCompileAt || 0)

			timeSinceStartedTrying = Date.now() - startedTryingAt
			timeSinceLastChange = Date.now() - $scope.docLastChangedAt

			shouldCompile = false
			if timeSinceLastChange > AUTO_COMPILE_DEBOUNCE # Don't compile in the middle of the user typing
				shouldCompile = true
			else if timeSinceStartedTrying > AUTO_COMPILE_MAX_WAIT # Unless they type for a long time
				shouldCompile = true
			else if timeSinceStartedTrying < 0 or timeSinceLastChange < 0
				# If time is non-monotonic, assume that the user's system clock has been
				# changed and continue with compile
				shouldCompile = true

			if shouldCompile
				triggerAutoCompile()

		triggerAutoCompile = () ->
			$scope.recompile(isAutoCompileOnChange: true)

		startTryingAutoCompile = () ->
			return if autoCompileInterval?
			$scope.startedTryingAutoCompileAt = Date.now()
			autoCompileInterval = setInterval autoCompileIfReady, 200

		stopTryingAutoCompile = () ->
			clearInterval autoCompileInterval
			autoCompileInterval = null

		$scope.$watch "uncompiledChanges", (uncompiledChanges) ->
			if uncompiledChanges
				startTryingAutoCompile()
			else
				stopTryingAutoCompile()

		$scope.uncompiledChanges = false
		recalculateUncompiledChanges = () ->
			if $scope.ui.pdfHidden
				# Don't bother auto-compiling if pdf isn't visible
				$scope.uncompiledChanges = false
			else if !$scope.docLastChangedAt?
				$scope.uncompiledChanges = false
			else if !$scope.lastStartedCompileAt? or $scope.docLastChangedAt > $scope.lastStartedCompileAt
				$scope.uncompiledChanges = true
			else
				$scope.uncompiledChanges = false

		_updateDocLastChangedAt = () ->
			$scope.docLastChangedAt = Date.now()
			recalculateUncompiledChanges()

		onDocChanged = () ->
			$scope.autoCompileLintingError = false
			_updateDocLastChangedAt()

		onDocSaved = () ->
			# We use the save as a trigger too, to account for the delay between the client
			# and server. Otherwise, we might have compiled after the user made
			# the change on the client, but before the server had it.
			_updateDocLastChangedAt()

		onCompilingStateChanged = (compiling) ->
			recalculateUncompiledChanges()

		autoCompileListeners = []
		toggleAutoCompile = (enabling) ->
			if enabling
				autoCompileListeners = [
					ide.$scope.$on "doc:changed", onDocChanged
					ide.$scope.$on "doc:saved", onDocSaved
					$scope.$watch "pdf.compiling", onCompilingStateChanged
				]
			else
				for unbind in autoCompileListeners
					unbind()
				autoCompileListeners = []
				$scope.autoCompileLintingError = false

		$scope.autocompile_enabled = localStorage("autocompile_enabled:#{$scope.project_id}") or false
		$scope.$watch "autocompile_enabled", (newValue, oldValue) ->
			if newValue? and oldValue != newValue
				localStorage("autocompile_enabled:#{$scope.project_id}", newValue)
				toggleAutoCompile(newValue)
				event_tracking.sendMB "autocompile-setting-changed", { value: newValue }

		if $scope.autocompile_enabled
			toggleAutoCompile(true)

		# abort compile if syntax checks fail
		$scope.stop_on_validation_error = localStorage("stop_on_validation_error:#{$scope.project_id}")
		$scope.stop_on_validation_error ?= true # turn on for all users by default
		$scope.$watch "stop_on_validation_error", (new_value, old_value) ->
			if new_value? and old_value != new_value
				localStorage("stop_on_validation_error:#{$scope.project_id}", new_value)

		$scope.draft = localStorage("draft:#{$scope.project_id}") or false
		$scope.$watch "draft", (new_value, old_value) ->
			if new_value? and old_value != new_value
				localStorage("draft:#{$scope.project_id}", new_value)

		sendCompileRequest = (options = {}) ->
			url = "/project/#{$scope.project_id}/compile"
			params = {}
			if options.isAutoCompileOnLoad or options.isAutoCompileOnChange
				params["auto_compile"]=true
			# if the previous run was a check, clear the error logs
			$scope.pdf.logEntries = [] if $scope.check
			# keep track of whether this is a compile or check
			$scope.check = if options.check then true else false
			event_tracking.sendMB "syntax-check-request" if options.check
			# send appropriate check type to clsi
			checkType = switch
				when $scope.check then "validate" # validate only
				when options.try then "silent" # allow use to try compile once
				when $scope.stop_on_validation_error then "error" # try to compile
				else "silent" # ignore errors
			return $http.post url, {
				rootDoc_id: options.rootDocOverride_id or null
				draft: $scope.draft
				check: checkType
				# use incremental compile for all users but revert to a full
				# compile if there is a server error
				incrementalCompilesEnabled: not $scope.pdf.error
				_csrf: window.csrfToken
			}, {params: params}

		parseCompileResponse = (response) ->

			# keep last url
			last_pdf_url = $scope.pdf.url
			pdfDownloadDomain = response.pdfDownloadDomain
			# Reset everything
			$scope.pdf.error      = false
			$scope.pdf.timedout   = false
			$scope.pdf.failure    = false
			$scope.pdf.url        = null
			$scope.pdf.clsiMaintenance = false
			$scope.pdf.tooRecentlyCompiled = false
			$scope.pdf.renderingError = false
			$scope.pdf.projectTooLarge = false
			$scope.pdf.compileTerminated = false
			$scope.pdf.compileExited = false
			$scope.pdf.failedCheck = false
			$scope.pdf.compileInProgress = false
			$scope.pdf.autoCompileDisabled = false

			buildPdfDownloadUrl = (path)->
				if pdfDownloadDomain?
					return "#{pdfDownloadDomain}#{path}"
				else
					return path
			# make a cache to look up files by name
			fileByPath = {}
			if response?.outputFiles?
				for file in response?.outputFiles
					fileByPath[file.path] = file

			# prepare query string
			qs = {}
			# add a query string parameter for the compile group
			if response.compileGroup?
				ide.compileGroup = qs.compileGroup = response.compileGroup
			# add a query string parameter for the clsi server id
			if response.clsiServerId?
				ide.clsiServerId = qs.clsiserverid = response.clsiServerId

			if response.status == "timedout"
				$scope.pdf.view = 'errors'
				$scope.pdf.timedout = true
				fetchLogs(fileByPath)
			else if response.status == "terminated"
				$scope.pdf.view = 'errors'
				$scope.pdf.compileTerminated = true
				fetchLogs(fileByPath)
			else if response.status in ["validation-fail", "validation-pass"]
				$scope.pdf.view = 'pdf'
				$scope.pdf.url = buildPdfDownloadUrl last_pdf_url
				$scope.shouldShowLogs = true
				$scope.pdf.failedCheck = true if response.status is "validation-fail"
				event_tracking.sendMB "syntax-check-#{response.status}"
				fetchLogs(fileByPath, { validation: true })
			else if response.status == "exited"
				$scope.pdf.view = 'pdf'
				$scope.pdf.compileExited = true
				$scope.pdf.url = buildPdfDownloadUrl last_pdf_url
				$scope.shouldShowLogs = true
				fetchLogs(fileByPath)
			else if response.status == "autocompile-backoff"
				if $scope.pdf.isAutoCompileOnLoad # initial autocompile
					$scope.pdf.view = 'uncompiled'
				else # background autocompile from typing
					$scope.pdf.view = 'errors'
					$scope.pdf.autoCompileDisabled = true
					$scope.autocompile_enabled = false # disable any further autocompiles
					event_tracking.sendMB "autocompile-rate-limited", {hasPremiumCompile: $scope.hasPremiumCompile}
			else if response.status == "project-too-large"
				$scope.pdf.view = 'errors'
				$scope.pdf.projectTooLarge = true
			else if response.status == "failure"
				$scope.pdf.view = 'errors'
				$scope.pdf.failure = true
				$scope.shouldShowLogs = true
				fetchLogs(fileByPath)
			else if response.status == 'clsi-maintenance'
				$scope.pdf.view = 'errors'
				$scope.pdf.clsiMaintenance = true
			else if response.status == "too-recently-compiled"
				$scope.pdf.view = 'errors'
				$scope.pdf.tooRecentlyCompiled = true
			else if response.status == "validation-problems"
				$scope.pdf.view = "validation-problems"
				$scope.pdf.validation = response.validationProblems
				$scope.shouldShowLogs = false
			else if response.status == "compile-in-progress"
				$scope.pdf.view = 'errors'
				$scope.pdf.compileInProgress = true
			else if response.status == "success"
				$scope.pdf.view = 'pdf'
				$scope.shouldShowLogs = false

				# define the base url. if the pdf file has a build number, pass it to the clsi in the url
				if fileByPath['output.pdf']?.url?
					$scope.pdf.url = buildPdfDownloadUrl fileByPath['output.pdf'].url
				else if fileByPath['output.pdf']?.build?
					build = fileByPath['output.pdf'].build
					$scope.pdf.url = buildPdfDownloadUrl "/project/#{$scope.project_id}/build/#{build}/output/output.pdf"
				else
					$scope.pdf.url = buildPdfDownloadUrl "/project/#{$scope.project_id}/output/output.pdf"
				# check if we need to bust cache (build id is unique so don't need it in that case)
				if not fileByPath['output.pdf']?.build?
					qs.cache_bust = "#{Date.now()}"
				# convert the qs hash into a query string and append it
				$scope.pdf.url += createQueryString qs
				# Save all downloads as files
				qs.popupDownload = true
				$scope.pdf.downloadUrl = "/project/#{$scope.project_id}/output/output.pdf" + createQueryString(qs)

				fetchLogs(fileByPath)

			IGNORE_FILES = ["output.fls", "output.fdb_latexmk"]
			$scope.pdf.outputFiles = []

			if !response.outputFiles?
				return

			# prepare list of output files for download dropdown
			qs = {}
			if response.clsiServerId?
				qs.clsiserverid = response.clsiServerId
			for file in response.outputFiles
				if IGNORE_FILES.indexOf(file.path) == -1
					isOutputFile = file.path.match(/^output\./)
					$scope.pdf.outputFiles.push {
						# Turn 'output.blg' into 'blg file'.
						name: if isOutputFile then "#{file.path.replace(/^output\./, "")} file" else file.path
						url: "/project/#{project_id}/output/#{file.path}" + createQueryString qs
						main: if isOutputFile then true else false
					}

			# sort the output files into order, main files first, then others
			$scope.pdf.outputFiles.sort (a,b) -> (b.main - a.main) || a.name.localeCompare(b.name)


		fetchLogs = (fileByPath, options) ->

			if options?.validation
				chktexFile = fileByPath['output.chktex']
			else
				logFile = fileByPath['output.log']
				blgFile = fileByPath['output.blg']

			getFile = (name, file) ->
				opts =
					method:"GET"
					params:
						compileGroup:ide.compileGroup
						clsiserverid:ide.clsiServerId
				if file?.url?  # FIXME clean this up when we have file.urls out consistently
					opts.url = file.url
				else if file?.build?
					opts.url = "/project/#{$scope.project_id}/build/#{file.build}/output/#{name}"
				else
					opts.url = "/project/#{$scope.project_id}/output/#{name}"
				# check if we need to bust cache (build id is unique so don't need it in that case)
				if not file?.build?
					opts.params.cache_bust = "#{Date.now()}"
				return $http(opts)

			# accumulate the log entries
			logEntries =
				all: []
				errors: []
				warnings: []

			accumulateResults = (newEntries) ->
				for key in ['all', 'errors', 'warnings']
					if newEntries.type?
						entry.type = newEntries.type for entry in newEntries[key]
					logEntries[key] = logEntries[key].concat newEntries[key]

			# use the parsers for each file type
			processLog = (log) ->
				$scope.pdf.rawLog = log
				{errors, warnings, typesetting} = HumanReadableLogs.parse(log, ignoreDuplicates: true)
				all = [].concat errors, warnings, typesetting
				accumulateResults {all, errors, warnings}

			processChkTex = (log) ->
				errors = []
				warnings = []
				for line in log.split("\n")
					if m = line.match /^(\S+):(\d+):(\d+): (Error|Warning): (.*)/
						result = { file:m[1], line:m[2], column:m[3], level:m[4].toLowerCase(), message: "#{m[4]}: #{m[5]}"}
						if result.level is 'error'
							errors.push result
						else
							warnings.push result
				all = [].concat errors, warnings
				logHints = HumanReadableLogs.parse {type: "Syntax", all, errors, warnings}
				event_tracking.sendMB "syntax-check-return-count", {errors:errors.length, warnings:warnings.length}
				accumulateResults logHints

			processBiber = (log) ->
				{errors, warnings} = BibLogParser.parse(log, {})
				all = [].concat errors, warnings
				accumulateResults {type: "BibTeX", all, errors, warnings}

			# output the results
			handleError = () ->
				$scope.pdf.logEntries = []
				$scope.pdf.rawLog = ""

			annotateFiles = () ->
				$scope.pdf.logEntries = logEntries
				$scope.pdf.logEntryAnnotations = {}
				for entry in logEntries.all
					if entry.file?
						entry.file = normalizeFilePath(entry.file)
						entity = ide.fileTreeManager.findEntityByPath(entry.file)
						if entity?
							$scope.pdf.logEntryAnnotations[entity.id] ||= []
							$scope.pdf.logEntryAnnotations[entity.id].push {
								row: entry.line - 1
								type: if entry.level == "error" then "error" else "warning"
								text: entry.message
							}

			# retrieve the logfile and process it
			if logFile?
				response = getFile('output.log', logFile)
					.then	(response) -> processLog(response.data)

				if blgFile?	# retrieve the blg file if present
					response = response.then () ->
						getFile('output.blg', blgFile)
							.then(
								(response) -> processBiber(response.data),
								() ->	true # ignore errors in biber file
							)

			if response?
				response.catch handleError
			else
				handleError()

			if chktexFile?
				getChkTex = () ->
					getFile('output.chktex', chktexFile)
						.then	(response) -> processChkTex(response.data)
				# always retrieve the chktex file if present
				if response?
					response = response.then getChkTex, getChkTex
				else
					response = getChkTex()

			# display the combined result
			if response?
				response.finally annotateFiles

		getRootDocOverride_id = () ->
			doc = ide.editorManager.getCurrentDocValue()
			return null if !doc?
			for line in doc.split("\n")
				match = line.match /^[^%]*\\documentclass/
				if match
					return ide.editorManager.getCurrentDocId()
			return null

		normalizeFilePath = (path) ->
			path = path.replace(/^(.*)\/compiles\/[0-9a-f]{24}(-[0-9a-f]{24})?\/(\.\/)?/, "")
			path = path.replace(/^\/compile\//, "")

			rootDocDirname = ide.fileTreeManager.getRootDocDirname()
			if rootDocDirname?
				path = path.replace(/^\.\//, rootDocDirname + "/")

			return path

		$scope.recompile = (options = {}) ->
			return if $scope.pdf.compiling

			event_tracking.sendMBSampled "editor-recompile-sampled", options

			$scope.lastStartedCompileAt = Date.now()
			$scope.pdf.compiling = true
			$scope.pdf.isAutoCompileOnLoad = options?.isAutoCompileOnLoad # initial autocompile

			if options?.force
				# for forced compile, turn off validation check and ignore errors
				$scope.stop_on_validation_error = false
				$scope.shouldShowLogs = false # hide the logs while compiling
				event_tracking.sendMB "syntax-check-turn-off-checking"

			if options?.try
				$scope.shouldShowLogs = false # hide the logs while compiling
				event_tracking.sendMB "syntax-check-try-compile-anyway"

			ide.$scope.$broadcast("flush-changes")

			options.rootDocOverride_id = getRootDocOverride_id()

			sendCompileRequest(options)
				.then (response) ->
					{ data } = response
					$scope.pdf.view = "pdf"
					$scope.pdf.compiling = false
					parseCompileResponse(data)
				.catch (response) ->
					{ data, status } = response
					if status == 429
						$scope.pdf.rateLimited = true
					$scope.pdf.compiling = false
					$scope.pdf.renderingError = false
					$scope.pdf.error = true
					$scope.pdf.view = 'errors'
				.finally () ->
					$scope.lastFinishedCompileAt = Date.now()

		# This needs to be public.
		ide.$scope.recompile = $scope.recompile
		# This method is a simply wrapper and exists only for tracking purposes.
		ide.$scope.recompileViaKey = () ->
			$scope.recompile { keyShortcut: true }

		$scope.stop = () ->
			return if !$scope.pdf.compiling

			$http {
				url: "/project/#{$scope.project_id}/compile/stop"
				method: "POST"
				params:
					clsiserverid:ide.clsiServerId
				headers:
					"X-Csrf-Token": window.csrfToken
			}

		$scope.clearCache = () ->
			$http {
				url: "/project/#{$scope.project_id}/output"
				method: "DELETE"
				params:
					clsiserverid:ide.clsiServerId
				headers:
					"X-Csrf-Token": window.csrfToken
			}

		$scope.toggleLogs = () ->
			$scope.shouldShowLogs = !$scope.shouldShowLogs
			event_tracking.sendMBOnce "ide-open-logs-once" if $scope.shouldShowLogs

		$scope.showPdf = () ->
			$scope.pdf.view = "pdf"
			$scope.shouldShowLogs = false

		$scope.toggleRawLog = () ->
			$scope.pdf.showRawLog = !$scope.pdf.showRawLog
			event_tracking.sendMB "logs-view-raw" if $scope.pdf.showRawLog

		$scope.openClearCacheModal = () ->
			modalInstance = $modal.open(
				templateUrl: "clearCacheModalTemplate"
				controller: "ClearCacheModalController"
				scope: $scope
			)

		$scope.syncToCode = (position) ->
			synctex
				.syncToCode(position)
				.then (data) ->
					{doc, line} = data
					ide.editorManager.openDoc(doc, gotoLine: line)

		$scope.switchToFlatLayout = () ->
			$scope.ui.pdfLayout = 'flat'
			$scope.ui.view = 'pdf'
			ide.localStorage "pdf.layout", "flat"

		$scope.switchToSideBySideLayout = () ->
			$scope.ui.pdfLayout = 'sideBySide'
			$scope.ui.view = 'editor'
			localStorage "pdf.layout", "split"

		if pdfLayout = localStorage("pdf.layout")
			$scope.switchToSideBySideLayout() if pdfLayout == "split"
			$scope.switchToFlatLayout() if pdfLayout == "flat"
		else
			$scope.switchToSideBySideLayout()

	App.factory "synctex", ["ide", "$http", "$q", (ide, $http, $q) ->
		# enable per-user containers by default
		perUserCompile = true

		synctex =
			syncToPdf: (cursorPosition) ->
				deferred = $q.defer()

				doc_id = ide.editorManager.getCurrentDocId()
				if !doc_id?
					deferred.reject()
					return deferred.promise
				doc = ide.fileTreeManager.findEntityById(doc_id)
				if !doc?
					deferred.reject()
					return deferred.promise
				path = ide.fileTreeManager.getEntityPath(doc)
				if !path?
					deferred.reject()
					return deferred.promise

				# If the root file is folder/main.tex, then synctex sees the
				# path as folder/./main.tex
				rootDocDirname = ide.fileTreeManager.getRootDocDirname()
				if rootDocDirname? and rootDocDirname != ""
					path = path.replace(RegExp("^#{rootDocDirname}"), "#{rootDocDirname}/.")

				{row, column} = cursorPosition

				$http({
						url: "/project/#{ide.project_id}/sync/code",
						method: "GET",
						params: {
							file: path
							line: row + 1
							column: column
							clsiserverid:ide.clsiServerId
						}
					})
					.then (response) ->
						{ data } = response
						deferred.resolve(data.pdf or [])
					.catch (response) ->
						error = response.data
						deferred.reject(error)

				return deferred.promise

			syncToCode: (position, options = {}) ->
				deferred = $q.defer()
				if !position?
					deferred.reject()
					return deferred.promise

				# FIXME: this actually works better if it's halfway across the
				# page (or the visible part of the page). Synctex doesn't
				# always find the right place in the file when the point is at
				# the edge of the page, it sometimes returns the start of the
				# next paragraph instead.
				h = position.offset.left

				# Compute the vertical position to pass to synctex, which
				# works with coordinates increasing from the top of the page
				# down.  This matches the browser's DOM coordinate of the
				# click point, but the pdf position is measured from the
				# bottom of the page so we need to invert it.
				if options.fromPdfPosition and position.pageSize?.height?
					v = (position.pageSize.height - position.offset.top) or 0 # measure from pdf point (inverted)
				else
					v = position.offset.top or 0 # measure from html click position

				# It's not clear exactly where we should sync to if it wasn't directly
				# clicked on, but a little bit down from the very top seems best.
				if options.includeVisualOffset
					v += 72 # use the same value as in pdfViewer highlighting visual offset

				$http({
						url: "/project/#{ide.project_id}/sync/pdf",
						method: "GET",
						params: {
							page: position.page + 1
							h: h.toFixed(2)
							v: v.toFixed(2)
							clsiserverid:ide.clsiServerId
						}
					})
					.then (response) ->
						{ data } = response
						if data.code? and data.code.length > 0
							doc = ide.fileTreeManager.findEntityByPath(data.code[0].file)
							return if !doc?
							deferred.resolve({doc: doc, line: data.code[0].line})
					.catch (response) ->
						error = response.data
						deferred.reject(error)

				return deferred.promise

		return synctex
	]

	App.controller "PdfSynctexController", ["$scope", "synctex", "ide", ($scope, synctex, ide) ->
		@cursorPosition = null
		ide.$scope.$on "cursor:editor:update", (event, @cursorPosition) =>

		$scope.syncToPdf = () =>
			return if !@cursorPosition?
			synctex
				.syncToPdf(@cursorPosition)
				.then (highlights) ->
					$scope.pdf.highlights = highlights

		$scope.syncToCode = () ->
			synctex
				.syncToCode($scope.pdf.position, includeVisualOffset: true, fromPdfPosition: true)
				.then (data) ->
					{doc, line} = data
					ide.editorManager.openDoc(doc, gotoLine: line)
	]

	App.controller "PdfLogEntryController", ["$scope", "ide", "event_tracking", ($scope, ide, event_tracking) ->
		$scope.openInEditor = (entry) ->
			event_tracking.sendMBOnce "logs-jump-to-location-once"
			entity = ide.fileTreeManager.findEntityByPath(entry.file)
			return if !entity? or entity.type != "doc"
			if entry.line?
				line = entry.line
			if entry.column?
				column = entry.column
			ide.editorManager.openDoc(entity, gotoLine: line, gotoColumn: column)
	]

	App.controller 'ClearCacheModalController', ["$scope", "$modalInstance", ($scope, $modalInstance) ->
		$scope.state =
			inflight: false

		$scope.clear = () ->
			$scope.state.inflight = true
			$scope
				.clearCache()
				.then () ->
					$scope.state.inflight = false
					$modalInstance.close()

		$scope.cancel = () ->
			$modalInstance.dismiss('cancel')
	]
