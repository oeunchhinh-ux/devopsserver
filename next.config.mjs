// next.config.mjs  ← ESM syntax
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  images: {
    unoptimized: true,
  },
};

export default nextConfig;   // ← NOT module.exports