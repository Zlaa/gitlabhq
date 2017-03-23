class ContainerImage < ActiveRecord::Base
  belongs_to :project

  delegate :container_registry,  to: :project
  delegate :client, to: :container_registry

  validates :manifest, presence: true

  before_destroy :delete_tags

  def registry
    # TODO, container registry with image access level
    token = Auth::ContainerRegistryAuthenticationService.image_token(self)
  end

  def tag(tag)
    ContainerRegistry::Tag.new(self, tag)
  end

  def manifest
    @manifest ||= client.repository_tags(name_with_namespace)
  end

  def tags
    return @tags if defined?(@tags)
    return [] unless manifest && manifest['tags']

    @tags = manifest['tags'].map do |tag|
      ContainerRegistry::Tag.new(self, tag)
    end
  end

  def blob(config)
    ContainerRegistry::Blob.new(self, config)
  end

  def delete_tags
    return unless tags

    digests = tags.map {|tag| tag.digest }.to_set
    digests.all? do |digest|
      client.delete_repository_tag(name_with_namespace, digest)
    end
  end

  def self.project_from_path(image_path)
    return unless image_path.include?('/')

    ##
    # Projects are always located inside a namespace, so we can remove
    # the last node, and see if project with that path exists.
    #
    truncated_path = image_path.slice(0...image_path.rindex('/'))

    ##
    # We still make it possible to search projects by a full image path
    # in order to maintain backwards compatibility.
    #
    Project.find_by_full_path(truncated_path) ||
        Project.find_by_full_path(image_path)
  end
end
