const form = document.querySelector("#auth-form");
const message = document.querySelector("#auth-message");
const password = document.querySelector("#password");
let mode = "login";
let csrfToken = "";

function showMessage(text, tone = "error") {
	message.textContent = text;
	message.dataset.tone = tone;
	message.hidden = false;
}

function setMode(nextMode) {
	mode = nextMode;
	const registering = mode === "register";
	document.querySelector("#signin-tab").setAttribute("aria-selected", String(!registering));
	document.querySelector("#register-tab").setAttribute("aria-selected", String(registering));
	document.querySelector("#name-field").hidden = !registering;
	document.querySelector("#email-field").hidden = !registering;
	document.querySelector("#login-options").hidden = registering;
	document.querySelector("#password-help").hidden = !registering;
	document.querySelector("#full-name").required = registering;
	document.querySelector("#register-email").required = registering;
	document.querySelector("#password").minLength = registering ? 12 : 1;
	document.querySelector("#password").autocomplete = registering ? "new-password" : "current-password";
	document.querySelector("#identifier").required = !registering;
	document.querySelector("#identifier").hidden = registering;
	document.querySelector("#identifier").parentElement.hidden = registering;
	document.querySelector("#auth-title").innerHTML = registering ? 'Create your <em>account.</em>' : 'Welcome <em>back.</em>';
	document.querySelector("#auth-subtitle").textContent = registering ? "Make an account to keep your favorites close." : "Sign in to your account to pick up where you left off.";
	document.querySelector("#auth-submit").innerHTML = registering ? 'Request account <span aria-hidden="true">→</span>' : 'Sign in <span aria-hidden="true">→</span>';
	document.querySelector("#approval-note").hidden = !registering;
	message.hidden = true;
	message.textContent = "";
}

async function apiRequest(path, options = {}) {
	const headers = new Headers(options.headers || {});
	if (options.body) headers.set("Content-Type", "application/json");
	if (options.method && options.method !== "GET") {
		if (!csrfToken) {
			const csrfResponse = await fetch("/api/v1/auth/csrf", { credentials: "same-origin" });
			if (!csrfResponse.ok) throw new Error("service_unavailable");
			csrfToken = (await csrfResponse.json()).csrfToken;
		}
		headers.set("X-CSRF-Token", csrfToken);
	}
	const response = await fetch(path, { ...options, headers, credentials: "same-origin" });
	let data = {};
	try { data = await response.json(); } catch { /* The API may return an empty response. */ }
	return { response, data };
}

for (const tab of document.querySelectorAll(".auth-tab")) {
	tab.addEventListener("click", () => setMode(tab.dataset.mode));
}

document.querySelector("#password-toggle").addEventListener("click", (event) => {
	const visible = password.type === "text";
	password.type = visible ? "password" : "text";
	event.currentTarget.textContent = visible ? "Show" : "Hide";
	event.currentTarget.setAttribute("aria-label", visible ? "Show password" : "Hide password");
});

document.querySelector("#forgot-password").addEventListener("click", () => {
	showMessage("For account help, contact the shop at ochiengreagan244@gmail.com or 0710 350 379.");
});

form.addEventListener("submit", async (event) => {
	event.preventDefault();
	message.hidden = true;
	if (!form.reportValidity()) return;
	const submit = document.querySelector("#auth-submit");
	submit.disabled = true;
	submit.textContent = mode === "register" ? "Sending request…" : "Signing in…";
	const values = new FormData(form);
	const payload = mode === "register"
		? { fullName: values.get("fullName").trim(), email: values.get("email").trim(), password: values.get("password") }
		: { identifier: values.get("identifier").trim(), password: values.get("password"), rememberMe: values.get("remember") === "on" };

	try {
		const { response, data } = await apiRequest(`/api/v1/auth/${mode}`, { method: "POST", body: JSON.stringify(payload) });
		if (mode === "register" && response.status === 202) {
			showMessage("Your account request has been sent. The shop admin must approve it before you can sign in.", "success");
			form.reset();
		} else if (response.status === 401) {
			showMessage("The username/email or password is incorrect. Check your details and try again.");
		} else if (response.status === 403 && data.error === "account_pending") {
			showMessage("Your account is waiting for admin approval. You’ll be able to sign in once it’s approved.");
		} else if (response.ok && mode === "login" && data.user) {
			window.location.assign(data.user.role === "admin" ? "admin.html" : "account.html");
		} else if (!response.ok) {
			showMessage("We couldn’t complete that request. Please check your details or contact the shop.");
		} else {
			showMessage("The account service returned an unexpected response. Please try again.");
		}
	} catch {
		showMessage("The secure account service isn’t connected. Your password was not sent or saved.");
	} finally {
		submit.disabled = false;
		submit.innerHTML = mode === "register" ? 'Request account <span aria-hidden="true">→</span>' : 'Sign in <span aria-hidden="true">→</span>';
	}
});
