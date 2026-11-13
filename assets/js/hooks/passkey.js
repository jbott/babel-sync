const toBytes = (text) => {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

const toText = (buffer) => {
  let binary = "";
  for (const byte of new Uint8Array(buffer)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

const create = async (options) => {
  const credential = await navigator.credentials.create({
    publicKey: {
      ...options,
      challenge: toBytes(options.challenge),
      user: { ...options.user, id: toBytes(options.user.id) },
      excludeCredentials: options.excludeCredentials.map((item) => ({ ...item, id: toBytes(item.id) })),
    },
  });

  return {
    attestationObject: toText(credential.response.attestationObject),
    clientDataJSON: toText(credential.response.clientDataJSON),
  };
};

const get = async (options) => {
  const credential = await navigator.credentials.get({
    publicKey: { ...options, challenge: toBytes(options.challenge) },
  });

  return {
    id: toText(credential.rawId),
    authenticatorData: toText(credential.response.authenticatorData),
    signature: toText(credential.response.signature),
    clientDataJSON: toText(credential.response.clientDataJSON),
  };
};

export const Passkey = {
  mounted() {
    this.el.addEventListener("click", () => {
      this.el.disabled = true;

      this.pushEvent("passkey_options", {}, async (reply) => {
        try {
          const result = reply.create ? await create(reply.create) : await get(reply.get);
          const nameField = document.getElementById(this.el.dataset.nameFrom);
          this.pushEvent("passkey_result", { ...result, name: nameField ? nameField.value : "" });
          if (nameField) nameField.value = "";
        } catch (error) {
          console.error("The passkey request failed:", error);
          this.pushEvent("passkey_failed", {});
        } finally {
          this.el.disabled = false;
        }
      });
    });
  },
};
