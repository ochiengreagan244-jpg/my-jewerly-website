 const products = [
	{ id: "orbit-hoops", name: "Orbit Hoops", category: "earrings", material: "Recycled sterling silver", price: 88, tag: "Best loved", image: "https://images.unsplash.com/photo-1617038220319-276d3cfab638?auto=format&fit=crop&w=900&q=82", alt: "Sculptural polished hoop earrings" },
	{ id: "soft-form-chain", name: "Soft Form Chain", category: "necklaces", material: "18k gold vermeil", price: 124, tag: "New", image: "https://images.unsplash.com/photo-1599643478518-a784e5dc4c8f?auto=format&fit=crop&w=900&q=82", alt: "Gold chain necklace with a minimal pendant" },
	{ id: "daylight-studs", name: "Daylight Studs", category: "earrings", material: "Recycled 14k gold", price: 96, tag: "Everyday", image: "https://images.unsplash.com/photo-1630019852942-f89202989a59?auto=format&fit=crop&w=900&q=82", alt: "Small gold stud earrings" },
	{ id: "li   ttle-elsewhere", name: "Little Elsewhere", category: "rings", material: "Recycled sterling silver", price: 112, tag: "Limited run", image: "https://images.unsplash.com/photo-1605100804763-247f67b3557e?auto=format&fit=crop&w=900&q=82", alt: "Silver ring with a clean sculptural profile" }
];

const productGrid = document.querySelector("#products");
const searchInput = document.querySelector("#product-search");
const bag = new Map();
let activeFilter = "all";
let toastTimer;

const money = (amount) => `$${amount.toFixed(0)}`;

function renderProducts() {
	const query = searchInput.value.trim().toLowerCase();
	const visibleProducts = products.filter((product) => {
		const matchesFilter = activeFilter === "all" || product.category === activeFilter;
		const matchesSearch = `${product.name} ${product.category} ${product.material}`.toLowerCase().includes(query);
		return matchesFilter && matchesSearch;
	});

	if (!visibleProducts.length) {
		productGrid.innerHTML = '<p class="empty-results">No pieces found. Try another search.</p>';
		return;
	}

	productGrid.innerHTML = visibleProducts.map((product, index) => `
		<article class="product-card" style="animation-delay:${index * 60}ms">
			<div class="product-image-wrap">
				<img class="product-image" src="${product.image}" alt="${product.alt}" loading="lazy" />
				<span class="product-tag">${product.tag}</span>
				<button class="favorite-button" type="button" aria-label="Save ${product.name} to favorites" aria-pressed="false">
					<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.4 8.8c0 4.3-8.4 10-8.4 10S3.6 13.1 3.6 8.8a4.3 4.3 0 0 1 8.4-1.2 4.3 4.3 0 0 1 8.4 1.2Z"/></svg>
				</button>
				<button class="button button-dark add-button" type="button" data-add="${product.id}">Add to bag <span aria-hidden="true">+</span></button>
			</div>
			<div class="product-info"><div><p class="product-name">${product.name}</p><span class="product-material">${product.material}</span></div><span class="product-price">${money(product.price)}</span></div>
		</article>`).join("");
}

function updateBag() {
	const count = [...bag.values()].reduce((total, item) => total + item.quantity, 0);
	const subtotal = [...bag.values()].reduce((total, item) => total + item.product.price * item.quantity, 0);
	document.querySelector("#bag-count").textContent = count;
	document.querySelector("#drawer-count").textContent = `(${count})`;
	document.querySelector("#bag-subtotal").textContent = money(subtotal);
	document.querySelector("#bag-trigger").setAttribute("aria-label", `Open shopping bag, ${count} ${count === 1 ? "item" : "items"}`);

	const bagItems = document.querySelector("#bag-items");
	if (!bag.size) {
		bagItems.innerHTML = '<p class="empty-bag">Your bag is taking a little breather. Find a piece you love and bring it along.</p>';
		return;
	}
	bagItems.innerHTML = [...bag.entries()].map(([id, item]) => `
		<article class="bag-item">
			<img src="${item.product.image}" alt="" />
			<div><h3>${item.product.name}</h3><p>${item.product.material} · Qty ${item.quantity}</p><p>${money(item.product.price * item.quantity)}</p></div>
			<button class="remove-item" type="button" data-remove="${id}">Remove</button>
		</article>`).join("");
}

function showToast(message) {
	const toast = document.querySelector("#toast");
	toast.textContent = message;
	toast.classList.add("visible");
	window.clearTimeout(toastTimer);
	toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 2200);
}

function setFilter(filter) {
	activeFilter = filter;
	document.querySelectorAll(".filter-button").forEach((button) => {
		const isActive = button.dataset.filter === filter;
		button.classList.toggle("active", isActive);
		button.setAttribute("aria-pressed", String(isActive));
	});
	renderProducts();
}

const drawer = document.querySelector("#bag-drawer");
const scrim = document.querySelector("#scrim");
function openBag() {
	drawer.classList.add("open");
	drawer.setAttribute("aria-hidden", "false");
	scrim.hidden = false;
	requestAnimationFrame(() => scrim.classList.add("visible"));
	document.querySelector("#bag-close").focus();
}
function closeBag() {
	drawer.classList.remove("open");
	drawer.setAttribute("aria-hidden", "true");
	scrim.classList.remove("visible");
	document.querySelector("#bag-trigger").focus();
	window.setTimeout(() => { if (!drawer.classList.contains("open")) scrim.hidden = true; }, 260);
}

productGrid.addEventListener("click", (event) => {
	const addButton = event.target.closest("[data-add]");
	if (addButton) {
		const product = products.find((item) => item.id === addButton.dataset.add);
		const existing = bag.get(product.id);
		bag.set(product.id, { product, quantity: (existing?.quantity ?? 0) + 1 });
		updateBag();
		showToast(`${product.name} added to your bag`);
		return;
	}
	const favoriteButton = event.target.closest(".favorite-button");
	if (favoriteButton) {
		const isFavorite = favoriteButton.getAttribute("aria-pressed") !== "true";
		favoriteButton.setAttribute("aria-pressed", String(isFavorite));
		showToast(isFavorite ? "Saved to your favorites" : "Removed from your favorites");
	}
});

document.querySelector("#bag-items").addEventListener("click", (event) => {
	const removeButton = event.target.closest("[data-remove]");
	if (!removeButton) return;
	bag.delete(removeButton.dataset.remove);
	updateBag();
});

document.querySelectorAll(".filter-button").forEach((button) => button.addEventListener("click", () => setFilter(button.dataset.filter)));
document.querySelectorAll("[data-filter-link]").forEach((link) => link.addEventListener("click", () => setFilter(link.dataset.filterLink)));
searchInput.addEventListener("input", renderProducts);
document.querySelector("#bag-trigger").addEventListener("click", openBag);
document.querySelector("#bag-close").addEventListener("click", closeBag);
scrim.addEventListener("click", closeBag);
document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeBag(); });

document.querySelector("#checkout-button").addEventListener("click", () => showToast("Checkout will be available when payments are connected."));

const menuButton = document.querySelector("#mobile-menu");
menuButton.addEventListener("click", () => {
	const isOpen = menuButton.getAttribute("aria-expanded") === "true";
	menuButton.setAttribute("aria-expanded", String(!isOpen));
	document.querySelector(".main-nav").classList.toggle("open", !isOpen);
});
document.querySelector(".main-nav").addEventListener("click", (event) => {
	if (event.target.closest("a")) {
		document.querySelector(".main-nav").classList.remove("open");
		menuButton.setAttribute("aria-expanded", "false");
	}
});

renderProducts();
updateBag();
