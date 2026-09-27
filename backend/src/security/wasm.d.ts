declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}

declare module "argon2id/lib/setup.js" {
  export interface Argon2idParams {
    password: Uint8Array;
    salt: Uint8Array;
    parallelism: number;
    passes: number;
    memorySize: number;
    tagLength: number;
    ad?: Uint8Array;
    secret?: Uint8Array;
  }
  export default function setupWasm(
    getSIMD: (imports: WebAssembly.Imports) => Promise<{ module: WebAssembly.Module; instance: WebAssembly.Instance }>,
    getNonSIMD: (imports: WebAssembly.Imports) => Promise<{ module: WebAssembly.Module; instance: WebAssembly.Instance }>,
  ): Promise<(params: Argon2idParams) => Uint8Array>;
}
