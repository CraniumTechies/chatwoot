class UpdateWidgetBrandUrlToSulwe < ActiveRecord::Migration[7.0]
  def up
    config = InstallationConfig.find_or_initialize_by(name: 'WIDGET_BRAND_URL')
    config.value = 'https://sulwe.dev'
    config.save!

    GlobalConfig.clear_cache
  end
end
