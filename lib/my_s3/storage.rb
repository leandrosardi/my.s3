# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'time'
require 'monitor'

module MyS3
  class StorageError < StandardError; end

  class Storage
    def initialize(root:, follow_symlinks: false)
      @root = Pathname.new(root).expand_path
      FileUtils.mkdir_p(@root)
      @follow_symlinks = follow_symlinks
      @lock = Monitor.new
    end

    def list(relative_path)
      directory = ensure_directory(relative_path, create: false)
      directories = []
      files = []

      each_child(directory) do |entry_path, stat|
        next if stat.symlink? && !@follow_symlinks

        entry_relative = relative_path_of(entry_path)
        payload = base_payload(entry_path, entry_relative, stat)
        stat.directory? ? directories << payload : files << payload.merge(size_bytes: stat.size)
      end

      {
        path: normalized_relative_path(relative_path),
        directories: directories.sort_by { |entry| entry[:name] },
        files: files.sort_by { |entry| entry[:name] }
      }
    end

    def create_folder(parent_path, folder_name)
      sanitized_name = sanitize_segment(folder_name)
      @lock.synchronize do
        parent_dir = ensure_directory(parent_path, create: true)
        target = parent_dir.join(sanitized_name)
        raise StorageError, 'Folder already exists' if target.exist?

        FileUtils.mkdir_p(target)
        directory_metadata(target)
      end
    end

    def delete_folder(path)
      normalized = normalized_relative_path(path)
      raise StorageError, 'Cannot delete the storage root' if normalized.empty?

      @lock.synchronize do
        target = ensure_directory(path, create: false)
        FileUtils.rm_rf(target)
      end

      { deleted: true, path: normalized }
    end

    def rename_folder(path, new_name)
      sanitized_name = sanitize_segment(new_name)
      normalized = normalized_relative_path(path)
      raise StorageError, 'Cannot rename the storage root' if normalized.empty?

      @lock.synchronize do
        source = ensure_directory(path, create: false)
        destination = source.dirname.join(sanitized_name)
        raise StorageError, 'Target name already exists' if destination.exist?

        FileUtils.mv(source, destination)
        directory_metadata(destination)
      end
    end

    def upload_file(relative_path, tempfile, original_filename)
      filename = sanitize_segment(File.basename(original_filename.to_s))
      raise StorageError, 'File name is required' if filename.empty?

      @lock.synchronize do
        destination_dir = ensure_directory(relative_path, create: true)
        target = destination_dir.join(filename)
        tempfile.rewind
        File.open(target, 'wb') { |file| IO.copy_stream(tempfile, file) }
        file_metadata(target)
      end
    end

    def delete_file(relative_path, filename)
      sanitized_filename = sanitize_segment(File.basename(filename.to_s))

      @lock.synchronize do
        directory = ensure_directory(relative_path, create: false)
        target = directory.join(sanitized_filename)
        raise StorageError, 'File not found' unless target.file?

        target.delete
        { deleted: true, path: relative_path_of(target) }
      end
    end

    def delete_older_than(relative_path, threshold_time)
      directory = ensure_directory(relative_path, create: false)
      deleted = []

      @lock.synchronize do
        Dir.glob(directory.join('**/*')).each do |entry|
          entry_path = Pathname.new(entry)
          next unless entry_path.file?
          next if entry_path.symlink? && !@follow_symlinks

          stat = entry_path.stat
          next unless stat.mtime < threshold_time

          entry_path.delete
          deleted << relative_path_of(entry_path)
        end
      end

      { deleted: deleted }
    end

    def public_path(relative_path, filename)
      sanitized_filename = sanitize_segment(File.basename(filename.to_s))
      segments = [normalized_relative_path(relative_path), sanitized_filename].reject(&:empty?)
      segments.join('/')
    end

    private

    def base_payload(entry_path, entry_relative, stat)
      {
        name: entry_path.basename.to_s,
        path: entry_relative,
        modified_at: stat.mtime.utc.iso8601
      }
    end

    def directory_metadata(path)
      stat = path.stat
      base_payload(path, relative_path_of(path), stat)
    end

    def file_metadata(path)
      stat = path.stat
      base_payload(path, relative_path_of(path), stat).merge(size_bytes: stat.size)
    end

    def each_child(directory)
      Dir.children(directory).each do |entry|
        entry_path = directory.join(entry)
        stat = entry_path.lstat
        next if stat.symlink? && !@follow_symlinks
        yield(entry_path, stat)
      end
    end

    def ensure_directory(relative_path, create: false)
      absolute = resolve_path(relative_path)
      if create
        FileUtils.mkdir_p(absolute)
      else
        raise StorageError, 'Path does not exist' unless absolute.directory?
      end
      absolute
    end

    def resolve_path(relative_path)
      sanitized = normalized_relative_path(relative_path)
      absolute = sanitized.empty? ? @root : @root.join(sanitized)
      absolute = absolute.expand_path
      raise StorageError, 'Path is outside of the storage root' unless inside_root?(absolute)
      ensure_no_symlinks!(absolute) unless @follow_symlinks
      absolute
    end

    def normalized_relative_path(relative_path)
      value = relative_path.to_s.strip
      return '' if value.empty?

      sanitized = Pathname.new(value).cleanpath.to_s
      sanitized = sanitized.sub(%r{^/}, '')
      sanitized == '.' ? '' : sanitized
    rescue ArgumentError
      raise StorageError, 'Invalid path'
    end

    def sanitize_segment(value)
      name = value.to_s.strip
      raise StorageError, 'Name cannot be empty' if name.empty?
      if name.include?('/') || name.include?('\\') || name.include?("\0") || name == '.' || name == '..'
        raise StorageError, 'Invalid name'
      end

      name
    end

    def inside_root?(absolute)
      absolute.to_s.start_with?(@root.to_s + File::SEPARATOR) || absolute == @root
    end

    def ensure_no_symlinks!(absolute)
      return if absolute == @root

      relative = absolute.relative_path_from(@root)
      current = @root
      relative.each_filename do |segment|
        current = current.join(segment)
        raise StorageError, 'Symlinks are not allowed' if current.symlink?
      end
    rescue ArgumentError
      raise StorageError, 'Path traversal detected'
    end

    def relative_path_of(path)
      relative = path.expand_path.relative_path_from(@root).to_s
      relative == '.' ? '' : relative
    end
  end
end
