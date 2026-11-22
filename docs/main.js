// Copies the install command.
const copy = document.getElementById("copy");
copy.addEventListener("click", async () => {
  const label = copy.querySelector("span");
  try {
    await navigator.clipboard.writeText(document.getElementById("cmd-text").textContent);
    copy.classList.add("ok");
    label.textContent = "Copied";
  } catch {
    label.textContent = "Select and copy";
  }
  setTimeout(() => { copy.classList.remove("ok"); label.textContent = "Copy"; }, 2000);
});
