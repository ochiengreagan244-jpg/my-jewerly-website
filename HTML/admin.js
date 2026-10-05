const statusBanner = document.querySelector("#admin-status");
const workspace = document.querySelector("#admin-workspace");
const denied = document.querySelector("#access-denied");
const signOutButton = document.querySelector("#admin-signout");
let csrfToken = "";

function setStatus(text, tone = "info") {
	statusBanner.textContent = text;
	statusBanner.dataset.tone = tone;
	statusBanner.hidden = false;
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

function escapeHtml(value = "") {
	return String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

function renderAccounts(accounts = []) {
	const body = document.querySelector("#account-requests");
	document.querySelector("#account-count").textContent = accounts.length;
	body.innerHTML = accounts.length ? accounts.map((account) => `<tr><td>${escapeHtml(account.fullName)}</td><td>${escapeHtml(account.email)}</td><td>${escapeHtml(account.createdAt || "—")}</td><td><div class="admin-actions"><button class="admin-action approve" data-kind="account" data-id="${escapeHtml(account.id)}" data-decision="approve" type="button">Approve</button><button class="admin-action" data-kind="account" data-id="${escapeHtml(account.id)}" data-decision="reject" type="button">Reject</button></div></td></tr>`).join("") : '<tr><td class="admin-empty" colspan="4">No account requests to review.</td></tr>';
}

function renderMovements(movements = []) {
	const body = document.querySelector("#movement-requests");
	document.querySelector("#movement-count").textContent = movements.length;
	body.innerHTML = movements.length ? movements.map((movement) => `<tr><td>${escapeHtml(movement.itemName)}</td><td>${escapeHtml(movement.direction)}</td><td>${escapeHtml(movement.quantity)}</td><td>${escapeHtml(movement.requestedBy)}</td><td>${escapeHtml(movement.reason || "—")}</td><td><div class="admin-actions"><button class="admin-action approve" data-kind="movement" data-id="${escapeHtml(movement.id)}" data-decision="approve" type="button">Approve</button><button class="admin-action" data-kind="movement" data-id="${escapeHtml(movement.id)}" data-decision="reject" type="button">Reject</button></div></td></tr>`).join("") : '<tr><td class="admin-empty" colspan="6">No inventory movements to review.</td></tr>';
}

function renderInventory(items = []) {
	const body = document.querySelector("#inventory-items");
	body.innerHTML = items.length ? items.map((item) => `<tr><td>${escapeHtml(item.itemName)}</td><td>${escapeHtml(item.quantity)}</td><td>${escapeHtml(item.updatedAt || "—")}</td></tr>`).join("") : '<tr><td class="admin-empty" colspan="3">No inventory has been added yet.</td></tr>';
}

async function loadWorkspace() {
	try {
		const { response: sessionResponse, data: sessionData } = await apiRequest("/api/v1/auth/session");
		if (!sessionResponse.ok || !sessionData.user) {
			denied.hidden = false;
			statusBanner.hidden = true;
			return;
		}
		if (sessionData.user.role !== "admin") {
			denied.hidden = false;
			statusBanner.hidden = true;
			return;
		}
		signOutButton.hidden = false;
		const { response, data } = await apiRequest("/api/v1/admin/dashboard");
		if (response.status === 401 || response.status === 403) {
			denied.hidden = false;
			statusBanner.hidden = true;
			return;
		}
		if (!response.ok) throw new Error("dashboard_unavailable");
		workspace.hidden = false;
		statusBanner.hidden = true;
		renderAccounts(data.accountApprovals || []);
		renderMovements(data.movementApprovals || []);
		document.querySelector("#inventory-count").textContent = data.inventorySummary?.items ?? 0;
		renderInventory(data.inventorySummary?.stockItems || []);
	} catch {
		setStatus("The secure shop service is unavailable. Admin data and actions remain locked until it reconnects.", "error");
	}
}

workspace.addEventListener("click", async (event) => {
	const button = event.target.closest("[data-kind][data-decision]");
	if (!button) return;
	button.disabled = true;
	const isAccount = button.dataset.kind === "account";
	const path = isAccount
		? `/api/v1/admin/accounts/${encodeURIComponent(button.dataset.id)}/decision`
		: `/api/v1/admin/movements/${encodeURIComponent(button.dataset.id)}/decision`;
	try {
		const { response } = await apiRequest(path, { method: "POST", body: JSON.stringify({ decision: button.dataset.decision }) });
		if (!response.ok) throw new Error("action_failed");
		setStatus("Decision recorded.", "success");
		await loadWorkspace();
	} catch {
		setStatus("That action could not be saved. Please retry when the secure shop service is online.", "error");
		button.disabled = false;
	}
});

document.querySelector("#inventory-form").addEventListener("submit", async (event) => {
	event.preventDefault();
	const form = event.currentTarget;
	if (!form.reportValidity()) return;
	const submit = form.querySelector('button[type="submit"]');
	submit.disabled = true;
	const values = new FormData(form);
	try {
		const { response } = await apiRequest("/api/v1/admin/inventory/items", {
			method: "POST",
			body: JSON.stringify({ itemName: values.get("itemName").trim(), quantity: Number(values.get("quantity")) })
		});
		if (!response.ok) throw new Error("inventory_save_failed");
		form.reset();
		document.querySelector("#inventory-quantity").value = "0";
		setStatus("Inventory saved.", "success");
		await loadWorkspace();
	} catch {
		setStatus("Inventory could not be saved. Please retry when the secure shop service is online.", "error");
	} finally {
		submit.disabled = false;
	}
});

signOutButton.addEventListener("click", async () => {
	try { await apiRequest("/api/v1/auth/logout", { method: "POST", body: "{}" }); } finally { window.location.assign("login.html"); }
});

loadWorkspace();
