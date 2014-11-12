module Permalinkable
  extend ActiveSupport::Concern

  included do
    before_create :generate_permalink
    validate :validate_unique_permalink
  end

  module ClassMethods
    def find_by_param!(param)
      find_by_permalink!(param)
    end
  end

  def to_param
    permalink
  end

  private

  def permalink_scope
    self.class.unscoped
  end

  def generate_permalink
    base = permalink_base.parameterize
    self.permalink = base
    if permalink_taken?
      self.permalink = "#{base}-#{SecureRandom.hex(4)}"
    end
  end

  def permalink_taken?
    scope = permalink_scope.where(permalink: permalink)
    scope = scope.where("id <> ?", id) if persisted?
    scope.exists?
  end

  def validate_unique_permalink
    errors.add(:permalink, :taken) if permalink_taken?
  end
end