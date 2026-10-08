// Adds (or with "remove", takes out) Nook's hooks in ~/.claude/settings.json, keeping everything
// else, including other commands that share a hook group with Nook's. Each hook runs
// `Nook --claude-hook <pid>`, which keeps only an event's lifecycle fields (session, event, folder,
// transcript path) in Nook's inbox; tool input and output are never written anywhere.
// The previous settings are saved as settings.json.nook-backup.
// Run: osascript -l JavaScript tools/claude-hooks.js add /Applications/Nook.app
//      osascript -l JavaScript tools/claude-hooks.js remove
ObjC.import('Foundation')

// Earlier versions copied the whole event into the inbox with this command.
const legacy = 'd="$HOME/Library/Application Support/Nook/inbox"; [ -d "$d" ] && cat > "$d/.claude-$PPID" && mv -f "$d/.claude-$PPID" "$d/claude-$PPID.hook"; exit 0'
const isNook = hook => hook.command === legacy || /\/Nook\.app\/Contents\/MacOS\/Nook' --claude-hook "\$PPID"/.test(hook.command || '')

const events = {
  UserPromptSubmit: null,
  PreToolUse: 'AskUserQuestion',
  PostToolUse: null, // back to "working" once a question or approval is answered
  Notification: 'permission_prompt|elicitation_dialog',
  Stop: null,
  StopFailure: null,
  SessionEnd: null,
}

const fileManager = $.NSFileManager.defaultManager
const isObject = value => typeof value === 'object' && value !== null && !Array.isArray(value)

function fail(message, error) {
  throw new Error(message + (error && !error.isNil() ? ': ' + error.localizedDescription.js : ''))
}

function read(path) {
  if (!fileManager.fileExistsAtPath(path)) return {}
  const error = $()
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, error)
  if (text.isNil()) fail('Could not read ' + path, error)
  let settings
  try { settings = JSON.parse(text.js) } catch (e) { fail(path + ' is not valid JSON, left unchanged (' + e.message + ')') }
  if (!isObject(settings)) fail(path + ' is not a JSON object, left unchanged')
  const hooks = settings.hooks === undefined ? {} : settings.hooks
  const valid = isObject(hooks) && Object.values(hooks).every(groups =>
    Array.isArray(groups) && groups.every(group => isObject(group) && (group.hooks === undefined || Array.isArray(group.hooks))))
  if (!valid) fail('Unexpected "hooks" layout in ' + path + ', left unchanged')
  return settings
}

function write(path, text) {
  const error = $()
  const dir = $(path).stringByDeletingLastPathComponent
  if (!fileManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), error)) fail('Could not create ' + dir.js, error)
  if (fileManager.fileExistsAtPath(path)) {
    const backup = path + '.nook-backup'
    fileManager.removeItemAtPathError(backup, null)
    if (!fileManager.copyItemAtPathToPathError(path, backup, error)) fail('Could not back up ' + path, error)
  }
  if (!$(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, error)) fail('Could not save ' + path, error)
}

function run(argv) {
  const [action, app] = argv
  if (action !== 'remove' && !(action === 'add' && app)) throw new Error('Usage: claude-hooks.js add /path/to/Nook.app | remove')
  const path = $.NSHomeDirectory().js + '/.claude/settings.json'
  const settings = read(path)
  const hooks = settings.hooks || {}

  // Take out only Nook's own hooks: other commands in the same group, and the group's matcher, stay.
  for (const event of Object.keys(hooks)) {
    const before = hooks[event].length
    hooks[event] = hooks[event].flatMap(group => {
      const kept = (group.hooks || []).filter(hook => !isNook(hook))
      if (kept.length === (group.hooks || []).length) return [group]
      return kept.length ? [Object.assign({}, group, { hooks: kept })] : []
    })
    if (before && !hooks[event].length) delete hooks[event]
  }

  if (action === 'add') {
    const executable = app.replace(/\/$/, '') + '/Contents/MacOS/Nook'
    if (executable.includes("'")) throw new Error('Nook.app path must not contain a quote: ' + app)
    // Prints nothing and always succeeds, so a missing Nook never gets in Claude Code's way.
    const command = "'" + executable + "' --claude-hook \"$PPID\" >/dev/null 2>&1; exit 0"
    for (const [event, matcher] of Object.entries(events)) {
      const group = { hooks: [{ type: 'command', command }] }
      if (matcher) group.matcher = matcher
      hooks[event] = (hooks[event] || []).concat([group])
    }
  }
  if (Object.keys(hooks).length) settings.hooks = hooks
  else delete settings.hooks
  write(path, JSON.stringify(settings, null, 2) + '\n')
  return (action === 'remove' ? 'Nook hooks removed from ' : 'Nook hooks added to ') + path
}
