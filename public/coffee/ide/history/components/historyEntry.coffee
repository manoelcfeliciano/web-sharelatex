define [
	"base"
	"ide/history/util/displayNameForUser"
], (App, displayNameForUser) ->
	historyEntryController = ($scope, $element, $attrs) ->
		ctrl = @
		ctrl.displayName = displayNameForUser
		ctrl.getProjectOpDoc = (projectOp) ->
			if projectOp.rename? then "#{ projectOp.rename.pathname} → #{ projectOp.rename.newPathname }"
			else if projectOp.add? then "#{ projectOp.add.pathname}"
			else if projectOp.remove? then "#{ projectOp.remove.pathname}"
		ctrl.getUserCSSStyle = (user) ->
			hue = user?.hue or 100
			if ctrl.entry.inSelection 
				color : "#FFF" 
			else 
				color: "hsl(#{ hue }, 70%, 50%)"
		return

	App.component "historyEntry", {
		bindings:
			entry: "<"
			currentUser: "<"
			onSelect: "&"
		controller: historyEntryController
		templateUrl: "historyEntryTpl"
	}