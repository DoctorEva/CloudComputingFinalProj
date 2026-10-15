const form = document.getElementById("image-input-form");
const imageInput = document.getElementById("image");
const preview = document.getElementById("preview");
const previewImage = document.getElementById("preview-image");
const previewName = document.getElementById("preview-name");
const output = document.getElementById("output");

const NUMERIC_FIELDS = new Set([
  "latitude",
  "longitude",
  "altitude",
  "horizontalAccuracy",
  "heading",
  "pitch",
  "roll",
]);
const EMPTY_OUTPUT = "<nothing submitted yet>";

// Relative path: the page and the API are served from the same CloudFront
// distribution. Point this at the distribution URL when running locally.
const API_ENDPOINT = "/api/images";

let previewUrl = null;

function clearPreview() {
  if (previewUrl) {
    URL.revokeObjectURL(previewUrl);
    previewUrl = null;
  }
  previewImage.removeAttribute("src");
  previewName.textContent = "";
  preview.hidden = true;
}

imageInput.addEventListener("change", () => {
  clearPreview();

  const file = imageInput.files[0];
  if (!file) {
    return;
  }

  previewUrl = URL.createObjectURL(file);
  previewImage.src = previewUrl;
  previewName.textContent = file.name;
  preview.hidden = false;
});

function collectMetadata() {
  const data = new FormData(form);
  const metadata = {};

  for (const [name, value] of data.entries()) {
    if (name === "image") {
      continue;
    }

    const trimmed = typeof value === "string" ? value.trim() : value;
    if (trimmed === "") {
      continue;
    }

    if (NUMERIC_FIELDS.has(name)) {
      const parsed = Number(trimmed);
      metadata[name] = Number.isNaN(parsed) ? trimmed : parsed;
    } else {
      metadata[name] = trimmed;
    }
  }

  return metadata;
}

async function requestUpload(file, metadata) {
  const response = await fetch(API_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...metadata,
      contentType: file.type,
      filename: file.name,
    }),
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.error || `Request failed with status ${response.status}`);
  }

  return body;
}

async function uploadToS3(uploadUrl, file) {
  // The Content-Type must match the value used when the URL was signed.
  const response = await fetch(uploadUrl, {
    method: "PUT",
    headers: { "Content-Type": file.type },
    body: file,
  });

  if (!response.ok) {
    throw new Error(`Upload failed with status ${response.status}`);
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const metadata = collectMetadata();
  const file = imageInput.files[0];
  const json = JSON.stringify(metadata, null, 2);

  // stdout
  console.log(json);

  if (!file) {
    output.textContent = `${json}\n\nError: choose an image before submitting.`;
    return;
  }

  const submitButton = form.querySelector('button[type="submit"]');
  submitButton.disabled = true;
  output.textContent = `${json}\n\nSubmitting metadata...`;

  try {
    const { uploadUrl, s3url } = await requestUpload(file, metadata);
    output.textContent = `${json}\n\nUploading image...`;

    await uploadToS3(uploadUrl, file);

    output.textContent = `${json}\n\nUploaded successfully.\n\n${s3url}`;
  } catch (error) {
    output.textContent = `${json}\n\nError: ${error.message}`;
  } finally {
    submitButton.disabled = false;
  }
});

form.addEventListener("reset", () => {
  clearPreview();
  output.textContent = EMPTY_OUTPUT;
});
