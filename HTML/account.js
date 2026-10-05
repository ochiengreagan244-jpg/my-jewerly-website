const workspace = document.querySelector("#account-workspace");
const statusBanner = document.querySelector("#account-status");
let csrfToken = "";

function setStatus(text, tone = "info") {
	statusBanner.textContent = text;
	statusBanner.dataset.tone = tone;
	statusBanner.hidden = false;
}

function escapeHtml(value = "") {
	return String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
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

async function loadCustomerPage() {
	try {
		const { response: sessionResponse, data: sessionData } = await apiRequest("/api/v1/auth/session");
		if (!sessionResponse.ok || sessionData.user?.role !== "customer" || sessionData.user?.status !== "approved") {
			window.location.assign("login.html");
			return;
		}
		document.querySelector("#customer-greeting").textContent = `Hello, ${sessionData.user.fullName || "there"}.`;
		const [inventoryResult, movementResult] = await Promise.all([
			apiRequest("/api/v1/inventory"),
			apiRequest("/api/v1/inventory/movements/mine")
		]);
		if (!inventoryResult.response.ok || !movementResult.response.ok) throw new Error("account_data_unavailable");
		const inventory = inventoryResult.data.items || [];
		const itemSelect = document.querySelector("#movement-item");
		itemSelect.innerHTML = '<option value="">Choose an item</option>' + inventory.map((item) => `<option value="${escapeHtml(item.itemName)}">${escapeHtml(item.itemName)} · ${escapeHtml(item.quantity)} in stock</option>`).join("");
		if (!inventory.length) document.querySelector("#movement-form-title").insertAdjacentHTML("afterend", '<p class="password-help">The shop admin has not added any inventory yet.</p>');
		renderMovements(movementResult.data.movements || []);
		statusBanner.hidden = true;
		workspace.hidden = false;
	} catch {
		setStatus("Your account service is unavailable. Account information and requests remain protected.", "error");
	}
}

function renderMovements(movements) {
	const body = document.querySelector("#my-movements");
	body.innerHTML = movements.length ? movements.map((movement) => `<tr><td>${escapeHtml(movement.itemName)}</td><td>${movement.direction === "in" ? "Stock in" : "Stock out"}</td><td>${escapeHtml(movement.quantity)}</td><td>${escapeHtml(movement.reason || "—")}</td><td><span class="movement-status" data-status="${escapeHtml(movement.status)}">${escapeHtml(movement.status)}</span></td><td>${escapeHtml(movement.createdAt || "—")}</td></tr>`).join("") : '<tr><td class="admin-empty" colspan="6">You have not requested any movements.</td></tr>';
}

document.querySelector("#movement-form").addEventListener("submit", async (event) => {
	event.preventDefault();
	const form = event.currentTarget;
	if (!form.reportValidity()) return;
	const submit = form.querySelector('button[type="submit"]');
	submit.disabled = true;
	const values = new FormData(form);
	try {
		const { response } = await apiRequest("/api/v1/inventory/movements", {
			method: "POST",
			body: JSON.stringify({ itemName: values.get("itemName"), direction: values.get("direction"), quantity: Number(values.get("quantity")), reason: values.get("reason").trim() })
		});
		if (!response.ok) throw new Error("movement_request_failed");
		form.reset();
		document.querySelector("#movement-quantity").value = "1";
		setStatus("Your movement request is waiting for admin approval.", "success");
		await loadCustomerPage();
	} catch {
		setStatus("Your request could not be saved. Check the item and try again.", "error");
	} finally {
		submit.disabled = false;
	}
});

document.querySelector("#account-signout").addEventListener("click", async () => {
	try { await apiRequest("/api/v1/auth/logout", { method: "POST", body: "{}" }); } finally { window.location.assign("login.html"); }
});

loadCustomerPage();
