"use client";

export default function Navbar({ searchBar }) {
  return (
    <>
      <nav className="w-full bg-[#0f1216] flex items-center justify-between px-4 py-2 shadow-[0_4px_6px_rgba(0,0,0,0.5)]">
        <div className="flex items-center gap-3 h-15">
          <img
            src="https://i.pinimg.com/736x/02/65/7a/02657a618b637e27942697e90567b686.jpg"
            alt="avatar"
            className="w-15 h-15 rounded-full object-cover border-2 border-white"
          />
          <span className="text-white font-semibold text-2xl">Group2 - CI/CD KAli deploy success</span>
        </div>

        {searchBar}
      </nav>
    </>
  );
}
