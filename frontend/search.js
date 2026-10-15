const form = document.getElementById("image-search-form");
const results = document.getElementById("search-results");
const status = document.getElementById("search-status");
const prevButton = document.getElementById("prev-page");
const nextButton = document.getElementById("next-page");

// Field groups mirror the query service filters.
const TEXT_FIELDS = ["name", "location", "description"];
const NUMERIC_FIELDS = [
  "latitude",
  "longitude",
  "altitude",
  "horizontalAccuracy",
  "heading",
  "pitch",
  "roll",
];
const DATETIME_FIELDS = ["imageDt", "createDt"];

const DEFAULT_LIMIT = 24;
const MAX_LIMIT = 500;

// Metadata shown on each result card: [api field, label].
const CARD_FIELDS = [
  ["imageDt", "Taken"],
  ["createDt", "Added"],
  ["latitude", "Lat"],
  ["longitude", "Lon"],
  ["altitude", "Altitude (m)"],
  ["horizontalAccuracy", "Accuracy (m)"],
  ["heading", "Heading"],
  ["pitch", "Pitch"],
  ["roll", "Roll"],
];

// Relative paths: the page and the API share one CloudFront distribution.
const API_ENDPOINT = "/images";
const IMAGE_ENDPOINT = "/image";

const EMPTY_STATUS = "Fill in one or more fields, then search.";

let offset = 0;
let lastCount = 0;
let lastLimit = DEFAULT_LIMIT;

// Mode radios live at `<field>Mode`; their inputs are grouped by data-mode.
function applyMode(field) {
  const block = form.querySelector(`.search-field[data-field="${field}"]`);
  if (!block) {
    return;
  }
  const selected = block.querySelector(`input[name="${field}Mode"]:checked`);
  const current = selected ? selected.value : "any";
  for (const input of block.querySelectorAll(".mode-inputs input")) {
    input.hidden = input.dataset.mode !== current;
  }
}

function applyAllModes() {
  for (const block of form.querySelectorAll(".search-field")) {
    applyMode(block.dataset.field);
  }
}

function valueOf(name) {
  const input = form.elements[name];
  if (!input || typeof input.value !== "string") {
    return "";
  }
  return input.value.trim();
}

// datetime-local yields "YYYY-MM-DDTHH:MM"; the API wants ISO-8601 with an
// explicit UTC zone, and the server's parser needs seconds present.
function toIsoUtc(value) {
  if (!value) {
    return "";
  }
  const [date, time] = value.split("T");
  if (!date || !time) {
    return value;
  }
  const withSeconds = time.split(":").length === 2 ? `${time}:00` : time;
  return `${date}T${withSeconds}Z`;
}

function buildQuery() {
  const params = new URLSearchParams();

  for (const field of TEXT_FIELDS) {
    const mode = form.querySelector(`input[name="${field}Mode"]:checked`)?.value;
    if (mode === "exact") {
      const value = valueOf(`${field}Exact`);
      if (value) {
        params.set(`${field}Exact`, value);
      }
    } else if (mode === "fuzzy") {
      const value = valueOf(`${field}Fuzzy`);
      if (value) {
        params.set(`${field}Fuzzy`, value);
      }
    }
  }

  for (const field of NUMERIC_FIELDS) {
    const mode = form.querySelector(`input[name="${field}Mode"]:checked`)?.value;
    if (mode === "exact") {
      const value = valueOf(`${field}Exact`);
      if (value) {
        params.set(`${field}Exact`, value);
      }
    } else if (mode === "range") {
      const minimum = valueOf(`${field}Min`);
      const maximum = valueOf(`${field}Max`);
      if (minimum) {
        params.set(`${field}Min`, minimum);
      }
      if (maximum) {
        params.set(`${field}Max`, maximum);
      }
    }
  }

  for (const field of DATETIME_FIELDS) {
    const mode = form.querySelector(`input[name="${field}Mode"]:checked`)?.value;
    if (mode === "exact") {
      const value = toIsoUtc(valueOf(`${field}Exact`));
      if (value) {
        params.set(`${field}Exact`, value);
      }
    } else if (mode === "range") {
      const since = toIsoUtc(valueOf(`${field}Since`));
      const before = toIsoUtc(valueOf(`${field}Before`));
      if (since) {
        params.set(`${field}Since`, since);
      }
      if (before) {
        params.set(`${field}Before`, before);
      }
    }
  }

  const s3url = valueOf("s3url");
  if (s3url) {
    params.set("s3url", s3url);
  }

  const bbox = valueOf("bbox");
  if (bbox) {
    params.set("bbox", bbox);
  }

  const fuzzyThreshold = valueOf("fuzzyThreshold");
  if (fuzzyThreshold) {
    params.set("fuzzyThreshold", fuzzyThreshold);
  }

  params.set("orderBy", form.elements.orderBy.value);
  params.set("order", form.elements.order.value);

  let limit = Number.parseInt(form.elements.limit.value, 10);
  if (Number.isNaN(limit)) {
    limit = DEFAULT_LIMIT;
  }
  limit = Math.min(Math.max(limit, 1), MAX_LIMIT);
  params.set("limit", String(limit));
  params.set("offset", String(offset));

  return { params, limit };
}

function buildCard(image) {
  const card = document.createElement("article");
  card.className = "result-card";

  const link = document.createElement("a");
  link.className = "result-image-link";
  link.href = `${IMAGE_ENDPOINT}?url=${encodeURIComponent(image.s3url)}`;
  link.target = "_blank";
  link.rel = "noopener";

  const img = document.createElement("img");
  img.loading = "lazy";
  img.alt = image.name || image.description || image.location || "Image";
  img.src = `${IMAGE_ENDPOINT}?url=${encodeURIComponent(image.s3url)}`;
  img.addEventListener("error", () => img.remove());
  link.appendChild(img);
  card.appendChild(link);

  const title = document.createElement("h3");
  title.className = "result-title";
  title.textContent = image.name || image.location || "(untitled)";
  card.appendChild(title);

  if (image.description) {
    const description = document.createElement("p");
    description.className = "result-description";
    description.textContent = image.description;
    card.appendChild(description);
  }

  const meta = document.createElement("dl");
  meta.className = "result-meta";
  if (typeof image.fuzzyScore === "number") {
    const scoreTerm = document.createElement("dt");
    scoreTerm.textContent = "Match";
    const scoreDetail = document.createElement("dd");
    scoreDetail.textContent = `${Math.round(image.fuzzyScore * 100)}%`;
    meta.append(scoreTerm, scoreDetail);
  }
  for (const [key, label] of CARD_FIELDS) {
    const value = image[key];
    if (value === null || value === undefined || value === "") {
      continue;
    }
    const term = document.createElement("dt");
    term.textContent = label;
    const detail = document.createElement("dd");
    detail.textContent = String(value);
    meta.append(term, detail);
  }
  card.appendChild(meta);

  return card;
}

function renderResults(payload) {
  results.replaceChildren();
  const images = Array.isArray(payload.images) ? payload.images : [];

  if (images.length === 0) {
    status.textContent = "No images matched.";
    return;
  }

  status.textContent = `Showing ${images.length} result${
    images.length === 1 ? "" : "s"
  } (offset ${payload.offset ?? offset}).`;

  const fragment = document.createDocumentFragment();
  for (const image of images) {
    fragment.appendChild(buildCard(image));
  }
  results.appendChild(fragment);
}

function updatePager() {
  prevButton.disabled = offset <= 0;
  nextButton.disabled = lastCount === 0 || lastCount < lastLimit;
}

function setBusy(busy) {
  const submitButton = form.querySelector('button[type="submit"]');
  submitButton.disabled = busy;
}

async function runSearch({ resetOffset = false } = {}) {
  if (resetOffset) {
    offset = 0;
  }

  const { params, limit } = buildQuery();
  lastLimit = limit;

  setBusy(true);
  status.textContent = "Searching...";

  try {
    const response = await fetch(`${API_ENDPOINT}?${params.toString()}`);
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(body.error || `Request failed with status ${response.status}`);
    }
    lastCount = typeof body.count === "number" ? body.count : 0;
    renderResults(body);
  } catch (error) {
    results.replaceChildren();
    status.textContent = `Error: ${error.message}`;
    lastCount = 0;
  } finally {
    setBusy(false);
    updatePager();
  }
}

form.addEventListener("change", (event) => {
  const target = event.target;
  if (target instanceof HTMLInputElement && target.type === "radio" && target.name.endsWith("Mode")) {
    applyMode(target.name.slice(0, -"Mode".length));
  }
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  runSearch({ resetOffset: true });
});

form.addEventListener("reset", () => {
  // The browser restores the default radios after this handler runs.
  window.setTimeout(applyAllModes, 0);
  offset = 0;
  lastCount = 0;
  results.replaceChildren();
  status.textContent = EMPTY_STATUS;
  updatePager();
});

prevButton.addEventListener("click", () => {
  offset = Math.max(0, offset - lastLimit);
  runSearch();
});

nextButton.addEventListener("click", () => {
  offset += lastLimit;
  runSearch();
});

applyAllModes();
updatePager();
