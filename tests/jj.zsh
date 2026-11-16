#!/usr/bin/env zsh

source "${0:A:h}/test-helper.zsh"

# jj integration is optional; skip when jj is not installed.
if (( ! $+commands[jj] )); then
	print -- "jj tests skipped (jj not installed)"
	exit 0
fi

set +e

# test-helper sources Pure with `set -u`, which aborts `prompt_pure_setup` before it autoloads `vcs_info`. Source it again so the Git fallback works in-process.
set +u
source ./pure.zsh >/dev/null 2>&1

# Runs the async job in $1 (passing any remaining arguments) and stores the parsed result in `info`.
jj_info() {
	local repository=$1
	shift
	local output
	output=$(builtin cd -q "$repository" && prompt_pure_async_vcs_info "$@")
	typeset -gA info=("${(@Q@)${(z)output}}")
}

# Prints the change ID of the working-copy revision in $1.
jj_rev() {
	local rev
	rev=$(builtin cd -q "$1" && command jj --ignore-working-copy log --no-graph -r @ -T 'change_id.short()')
	print -r -- "${rev[1,8]}"
}

# Renders the preprompt for the jj repository in $1 through the real async pipeline, like the git tests do. Sets `preprompt`.
render_preprompt() {
	local output
	output=$(command zsh -fc '
		setopt extendedglob
		source ./pure.zsh >/dev/null 2>&1
		async_job() {
			:
		}
		builtin cd -q "$1"
		typeset -g prompt_pure_async_inited=1
		typeset -g PROMPT_PURE_WORKER_GENERATION=1
		typeset -gA prompt_pure_worker_env=(pwd "$PWD" generation 1)
		prompt_pure_async_callback prompt_pure_async_vcs_info 0 "$(prompt_pure_async_vcs_info)" 0 "" 0
		prompt_pure_preprompt_render
		local preprompt=${${(S%%)PROMPT}%%$'\''\n'\''*}
		# Strip color escape sequences.
		print -r -- ${preprompt//$'\''\e'\''\[[0-9;]#m}
	' zsh "$1")
	typeset -g preprompt=$output
}

main() {
	zmodload -F zsh/files b:zf_rm b:zf_mkdir

	local repository=$PWD/.ai-temporary/pure-jj-$$
	local colocated=$repository-colocated
	local no_bookmark=$repository-no-bookmark
	local config=$repository.config.toml
	trap "zf_rm -rf -- ${(q)repository} ${(q)colocated} ${(q)no_bookmark} ${(q)config}" EXIT
	zf_mkdir -p -- "$repository" "$no_bookmark"

	# Do not depend on the user's jj config.
	print -r -- 'user.name = "Test"' >| "$config"
	print -r -- 'user.email = "test@test.com"' >> "$config"
	export JJ_CONFIG=$config

	command jj git init --no-colocate "$repository" >/dev/null 2>&1 || return 1
	command jj git init --no-colocate "$no_bookmark" >/dev/null 2>&1 || return 1

	# A bookmark on `@` renders without a distance.
	command jj -R "$repository" --ignore-working-copy bookmark create main -r @ >/dev/null 2>&1 || return 1
	local rev
	rev=$(jj_rev "$repository")
	jj_info "$repository"
	assert_equal jj "${info[vcs]-}" "a jj repository should be detected" || return
	assert_equal "$repository" "${info[top]-}" "the jj workspace root should be reported" || return
	assert_equal "$rev" "${info[jj_rev]-}" "the working-copy change ID should be reported" || return
	assert_equal main "${info[jj_bookmark]-}" "a bookmark on the working copy should be reported" || return
	assert_equal 0 "${info[jj_distance]-}" "a bookmark on the working copy has no distance" || return

	# Commits after the bookmark add to the distance.
	command jj -R "$repository" --ignore-working-copy new >/dev/null 2>&1 || return 1
	command jj -R "$repository" --ignore-working-copy new >/dev/null 2>&1 || return 1
	rev=$(jj_rev "$repository")
	jj_info "$repository"
	assert_equal "$rev" "${info[jj_rev]-}" "the new working-copy change ID should be reported" || return
	assert_equal main "${info[jj_bookmark]-}" "the nearest ancestor bookmark should be reported" || return
	assert_equal 2 "${info[jj_distance]-}" "the distance from the bookmark should be reported" || return

	# A subdirectory reports the workspace root.
	zf_mkdir -p -- "$repository/sub"
	jj_info "$repository/sub"
	assert_equal "$repository" "${info[top]-}" "a subdirectory should report the jj workspace root" || return
	assert_equal main "${info[jj_bookmark]-}" "a subdirectory should report the bookmark" || return

	# Without a bookmarked ancestor, only the change ID is shown.
	rev=$(jj_rev "$no_bookmark")
	jj_info "$no_bookmark"
	assert_equal jj "${info[vcs]-}" "a jj repository without bookmarks should be detected" || return
	assert_equal "$rev" "${info[jj_rev]-}" "the change ID should be reported without a bookmark" || return
	assert_empty "${info[jj_bookmark]-}" "no bookmark should be reported without a bookmarked ancestor" || return
	assert_empty "${info[jj_distance]-}" "no distance should be reported without a bookmarked ancestor" || return

	# The prompt renders the change ID followed by the bookmark and distance.
	rev=$(jj_rev "$repository")
	render_preprompt "$repository"
	assert_equal "${repository/#$HOME/~} $rev main+2" "$preprompt" "the preprompt should render the jj revision and bookmark" || return

	# jj takes precedence in a colocated repository, and disabling it falls back to Git.
	command jj git init --colocate "$colocated" >/dev/null 2>&1 || return 1
	jj_info "$colocated"
	assert_equal jj "${info[vcs]-}" "jj should take precedence in a colocated repository" || return
	assert_empty "${info[branch]-}" "the Git branch should not be reported in a jj repository" || return
	jj_info "$colocated" 1 0
	assert_empty "${info[vcs]-}" "disabling jj should skip jj detection" || return
	assert_equal "$colocated" "${info[top]-}" "disabling jj should fall back to Git" || return

	# Outside a repository, jj detection fails.
	assert_empty "$(builtin cd -q / && prompt_pure_async_jj_info)" "jj detection should fail outside a repository" || return

	print -- "jj tests passed"
}

main "$@"
