export const Uploader = {
  mounted() {
    this.el.addEventListener("change", async () => {
      const { vaultId, token } = this.el.dataset;
      const { sharedClient } = await import("./client");
      const client = sharedClient(token);
      const progress = document.getElementById("upload-progress");
      const files = [...this.el.files];
      this.el.value = "";

      for (const file of files) {
        try {
          if (progress) {
            progress.hidden = false;
            progress.value = 0;
          }

          const data = new Uint8Array(await file.arrayBuffer());
          const hash = await client.upload(vaultId, data, (sent, total) => {
            if (progress) progress.value = total === 0 ? 100 : Math.round((sent / total) * 100);
          });

          this.pushEvent("attach", { name: file.name, hash });
        } catch {
          this.pushEvent("upload_failed", { name: file.name });
        }
      }

      if (progress) progress.hidden = true;
    });
  },
};
