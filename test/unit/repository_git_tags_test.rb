# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'open3'

# Repository::Git#tag_revisions (RepositoryGitPatch) against a real git repository: the commits of the tags
class RepositoryGitTagsTest < ActiveSupport::TestCase
  fixtures :projects

  GIT = %w[git -c user.name=tester -c user.email=tester@example.com -c commit.gpgsign=false -c tag.gpgsign=false].freeze

  def setup
    skip 'git is not available' unless system('git', '--version', out: File::NULL, err: File::NULL)

    @dir = Dir.mktmpdir('rubysmart_deployment_tags')
    git('init', '-q', '.')
    @repository = Repository::Git.new(project: Project.find(1), url: File.join(@dir, '.git'))
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_lightweight_and_annotated_tags
    git('commit', '-q', '--allow-empty', '-m', 'first')
    git('tag', 'v1.0')
    git('commit', '-q', '--allow-empty', '-m', 'second')
    git('tag', '-a', 'release/v2.0', '-m', 'Release 2.0')
    first, second = git('rev-list', '--reverse', 'HEAD').split

    # the annotated tag is dereferenced to its commit (not the tag object)
    assert_equal({ 'release/v2.0' => second, 'v1.0' => first }, @repository.tag_revisions)
    assert_equal Encoding::UTF_8, @repository.tag_revisions.keys.first.encoding
  end

  def test_no_tags
    git('commit', '-q', '--allow-empty', '-m', 'first')

    assert_equal({}, @repository.tag_revisions)
  end

  private

  def git(*args)
    output, status = Open3.capture2(*GIT, *args, chdir: @dir)
    assert status.success?, "git #{args.join(' ')} failed"
    output
  end
end
