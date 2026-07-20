/**
 * Minimal static-asset Worker for tipscoach-reports.
 *
 * All static content lives under ./dist/ and is served via Workers Static
 * Assets (the ASSETS binding).  This Worker delegates every request to the
 * platform-managed static-asset handler.
 */
export default {
	async fetch(request, env) {
		return env.ASSETS.fetch(request);
	},
};
