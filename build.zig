const std = @import ("std");
const toolbox = @import ("toolbox");
const pkg = .{ .name = "shaderc.zig", .version = "2024.0.0", };

fn update (builder: *std.Build, include_path: [] const u8) !void
{
  std.fs.deleteTreeAbsolute (include_path) catch |err|
  {
    switch (err)
    {
      error.FileNotFound => {},
      else => return err,
    }
  };

  try toolbox.run (builder, .{ .argv = &[_][] const u8 { "git", "clone", "https://github.com/google/shaderc.git", include_path, }, });
  try toolbox.run (builder, .{ .argv = &[_][] const u8 { "git", "-C", include_path, "checkout", "v" ++ pkg.version [0 .. pkg.version.len - 2], }, });

  var include_dir = try std.fs.openDirAbsolute (include_path, .{ .iterate = true, });
  defer include_dir.close ();

  var it = include_dir.iterate ();
  while (try it.next ()) |entry|
  {
    if (!std.mem.startsWith (u8, entry.name, "libshaderc"))
      try std.fs.deleteTreeAbsolute (try std.fs.path.join (builder.allocator, &.{ include_path, entry.name, }));
  }

  var walker = try include_dir.walk (builder.allocator);
  defer walker.deinit ();

  while (try walker.next ()) |entry|
  {
    if (entry.kind == .file and ((toolbox.is_cpp_source_file (entry.basename) and
      std.mem.indexOf (u8, entry.basename, "test") != null) or
      (!toolbox.is_cpp_source_file (entry.basename) and !toolbox.is_c_header_file (entry.basename)
        and !std.mem.endsWith (u8, entry.basename, ".inc"))))
          try std.fs.deleteFileAbsolute (try std.fs.path.join (builder.allocator, &.{ include_path, entry.path, }));
  }

  var flag = true;

  while (flag)
  {
    flag = false;

    walker = try include_dir.walk (builder.allocator);
    defer walker.deinit ();

    while (try walker.next ()) |entry|
    {
      if (entry.kind == .directory)
      {
        std.fs.deleteDirAbsolute (try std.fs.path.join (builder.allocator, &.{ include_path, entry.path, })) catch |err|
        {
          if (err == error.DirNotEmpty) continue else return err;
        };
        flag = true;
      }
    }
  }
}

pub fn build (builder: *std.Build) !void
{
  const target = builder.standardTargetOptions (.{});
  const optimize = builder.standardOptimizeOption (.{});

  const include_path = try builder.build_root.join (builder.allocator, &.{ "include", });

  if (builder.option (bool, "update", "Update binding") orelse false) try update (builder, include_path);

  const lib = builder.addStaticLibrary (.{
    .name = "shaderc",
    .root_source_file = builder.addWriteFiles ().add ("empty.c", ""),
    .target = target,
    .optimize = optimize,
  });

  var sources = try std.BoundedArray ([] const u8, 256).init (0);

  const glslang_dep = builder.dependency ("glslang", .{
    .target = target,
    .optimize = optimize,
  });

  const spirv_dep = builder.dependency ("spirv", .{
    .target = target,
    .optimize = optimize,
  });

  const glslang_compile_step = glslang_dep.artifact ("glslang");
  const spirv_compile_step = spirv_dep.artifact ("spirv");
  lib.linkLibrary (glslang_compile_step);
  lib.installLibraryHeaders (glslang_compile_step);
  lib.linkLibrary (spirv_compile_step);
  lib.installLibraryHeaders (spirv_compile_step);

  for ([_] std.Build.LazyPath {
    .{ .path = try std.fs.path.join (builder.allocator, &.{ "include", "libshaderc", "include", }), },
    .{ .path = try std.fs.path.join (builder.allocator, &.{ "include", "libshaderc_util", "include", }), },
  }) |include|
  {
    std.debug.print ("[shaderc include] {s}\n", .{ include.getPath (builder), });
    lib.addIncludePath (include);
  }

  const shaderc_path = try std.fs.path.join (builder.allocator, &.{ include_path, "libshaderc", });
  const shaderc_include_path = try std.fs.path.join (builder.allocator, &.{ shaderc_path, "include", "shaderc", });
  lib.installHeadersDirectory (.{ .path = shaderc_include_path, }, "shaderc", .{ .include_extensions = &.{ ".h", }, });
  std.debug.print ("[shaderc headers dir] {s}\n", .{ shaderc_include_path, });

  const shaderc_util_path = try std.fs.path.join (builder.allocator, &.{ include_path, "libshaderc_util", });
  const shaderc_util_include_path = try std.fs.path.join (builder.allocator, &.{ shaderc_util_path, "include", "libshaderc_util", });
  lib.installHeadersDirectory (.{ .path = shaderc_util_include_path, }, "libshaderc_util", .{ .include_extensions = &.{ ".h", }, });
  std.debug.print ("[shaderc headers dir] {s}\n", .{ shaderc_util_include_path, });

  var dir: std.fs.Dir = undefined;
  var walker: std.fs.Dir.Walker = undefined;

  for ([_] struct { abs: [] const u8, rel: [] const u8, } {
    .{ .abs = shaderc_path, .rel = try std.fs.path.join (builder.allocator, &.{ "include", "libshaderc", }), },
    .{ .abs = shaderc_util_path, .rel = try std.fs.path.join (builder.allocator, &.{ "include", "libshaderc_util", }), },
  }) |paths|
  {
    dir = try std.fs.openDirAbsolute (paths.abs, .{ .iterate = true, });
    defer dir.close ();

    walker = try dir.walk (builder.allocator);
    defer walker.deinit ();

    while (try walker.next ()) |entry|
    {
      switch (entry.kind)
      {
        .file => if (toolbox.is_cpp_source_file (entry.basename))
                 {
                   try sources.append (try std.fs.path.join (builder.allocator, &.{ paths.rel, builder.dupe (entry.path), }));
                   std.debug.print ("[shaderc source] {s}\n", .{ try std.fs.path.join (builder.allocator, &.{ paths.abs, entry.path, }), });
                 },
        else => {},
      }
    }
  }

  lib.addCSourceFiles (.{
    .files = sources.slice (),
    .flags = &.{ "-DENABLE_HLSL", },
  });

  builder.installArtifact (lib);
}
