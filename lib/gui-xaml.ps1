# ----------------------------------------------------------------------------- # The window itself (XAML) # # Part of Store-Gui.ps1. Not runnable on its own: the entry script dot-sources # this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- XAML
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Store-Offline"
        Height="250" Width="1060" MinHeight="250" MinWidth="940"
        WindowStartupLocation="CenterScreen"
        Background="#0F1115" FontFamily="Segoe UI" FontSize="13"
        Foreground="#E6E9EE" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">

  <Window.Resources>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6E9EE"/>
      <Setter Property="Background" Value="#232830"/>
      <Setter Property="BorderBrush" Value="#313843"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="b" CornerRadius="8" Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"/>
              <Border x:Name="h" CornerRadius="8" Background="#FFFFFF" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="h" Property="Opacity" Value="0.09"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="h" Property="Opacity" Value="0.20"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#3B82F6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="20,9"/>
    </Style>

    <Style x:Key="BtnStop" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#7F1D1D"/>
      <Setter Property="BorderBrush" Value="#991B1B"/>
      <Setter Property="Foreground" Value="#FEE2E2"/>
    </Style>

    <Style x:Key="BtnFlat" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A93A0"/>
      <Setter Property="Padding" Value="10,9"/>
    </Style>

    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Foreground" Value="#E6E9EE"/>
      <Setter Property="Background" Value="#12151A"/>
      <Setter Property="BorderBrush" Value="#2A313B"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="#E6E9EE"/>
      <Setter Property="Padding" Value="11,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#161A20"/>
      <Setter Property="BorderBrush" Value="#262C35"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
    </Style>

    <Style x:Key="Row" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="11,8"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" CornerRadius="8" Background="Transparent"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1C222B"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1E3A8A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="4" Background="#1C222B"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" Background="#2563EB"
                      HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C3CAD4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Padding" Value="8,5"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#8A93A0"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="b" CornerRadius="7,7,0,0" Background="Transparent"
                    Padding="{TemplateBinding Padding}" Margin="0,0,3,0">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1C222B"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#232830"/>
                <Setter Property="Foreground" Value="#E6E9EE"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <Grid x:Name="rootGrid" Margin="20,16,20,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition x:Name="rowMain" Height="*"/>
      <RowDefinition x:Name="rowOpts" Height="Auto"/>
      <RowDefinition x:Name="rowBtns" Height="Auto"/>
      <RowDefinition x:Name="rowJobs" Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="2,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock x:Name="lblAppTitle" Text="Store-Offline" FontSize="21" FontWeight="SemiBold"/>
        <TextBlock x:Name="lblAppSub" Foreground="#7D8694" Margin="0,3,0,0" TextWrapping="Wrap"
                   Text="Download any Microsoft Store app together with the frameworks it needs. x64 when it exists, x86 when it does not. Installing is optional."/>
      </StackPanel>
      <Button x:Name="btnLang" Grid.Column="1" Content="English" Style="{StaticResource Btn}"
              VerticalAlignment="Top" Margin="12,0,0,0"
              ToolTip="Switch the interface language / تغيير لغة الواجهة"/>
    </Grid>

    <Grid Grid.Row="1" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="txtInput" Grid.Column="0" Style="{StaticResource Field}"
               ToolTip="Paste a Store link, a product id (9N... / XP...), or a name to search"/>
      <Button x:Name="btnSearch" Grid.Column="1" Content="Search"
              Style="{StaticResource Btn}" Margin="8,0,0,0"/>
    </Grid>

    <Grid x:Name="gridMain" Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource Card}" Padding="6">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="lblResultsHead" Grid.Row="0" Text="RESULTS" Foreground="#5C6673"
                     FontSize="10.5" FontWeight="SemiBold" Margin="11,8,0,4"/>
          <ListBox x:Name="lstResults" Grid.Row="1" Background="Transparent"
                   BorderThickness="0" ItemContainerStyle="{StaticResource Row}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        </Grid>
      </Border>

      <Border Grid.Column="2" Style="{StaticResource Card}" Padding="18,14">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock x:Name="lblAppHead" Grid.Row="0" Text="APP" Foreground="#5C6673"
                     FontSize="10.5" FontWeight="SemiBold" Margin="0,0,0,10"/>

          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Width="76" Height="76" CornerRadius="12"
                    Background="#1C222B" Margin="0,0,16,0" VerticalAlignment="Top">
              <Image x:Name="imgIcon" Stretch="Uniform" Margin="6"/>
            </Border>

            <StackPanel Grid.Column="1">
              <TextBlock x:Name="lblTitle" Text="Nothing selected" FontSize="18"
                         FontWeight="SemiBold" TextWrapping="Wrap"/>
              <TextBlock x:Name="lblPublisher" Foreground="#8A93A0" Margin="0,4,0,0"
                         TextWrapping="Wrap"/>

              <Grid Margin="0,14,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="105"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock x:Name="lblVersionCap" Grid.Row="0" Grid.Column="0" Text="Version" Foreground="#5C6673"/>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="lblVersion" Text="-"/>

                <TextBlock x:Name="lblSizeCap" Grid.Row="1" Grid.Column="0" Text="Download" Foreground="#5C6673" Margin="0,7,0,0"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="lblSize" Text="-" Margin="0,7,0,0"
                           FontWeight="SemiBold" Foreground="#7FB3FF"/>

                <TextBlock x:Name="lblDepsCap" Grid.Row="2" Grid.Column="0" Text="Frameworks" Foreground="#5C6673" Margin="0,7,0,0"/>
                <TextBlock Grid.Row="2" Grid.Column="1" x:Name="lblDeps" Text="-" Margin="0,7,0,0"
                           TextWrapping="Wrap"/>

                <TextBlock x:Name="lblDestCap" Grid.Row="3" Grid.Column="0" Text="Folder" Foreground="#5C6673" Margin="0,7,0,0"/>
                <TextBlock Grid.Row="3" Grid.Column="1" x:Name="lblDest" Text="-" Margin="0,7,0,0"
                           TextWrapping="Wrap" Foreground="#8A93A0" FontSize="12"/>
              </Grid>
            </StackPanel>
          </Grid>

          <TextBlock Grid.Row="2" x:Name="lblHint" Foreground="#5C6673" TextWrapping="Wrap"
                     FontSize="12" Margin="0,12,0,0"
                     Text="Paste a Microsoft Store link, or type a name and press Search."/>
        </Grid>
      </Border>
    </Grid>

    <StackPanel x:Name="gridOpts" Grid.Row="3" Orientation="Horizontal" Margin="2,14,0,0">
      <TextBlock x:Name="lblArchCap" Text="Architecture" Foreground="#8A93A0"
                 VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="cmbArch" Width="92" SelectedIndex="0"
                ToolTip="x64 falls back to x86 automatically when the app has no x64 build">
        <ComboBoxItem>x64</ComboBoxItem>
        <ComboBoxItem>x86</ComboBoxItem>
        <ComboBoxItem>arm64</ComboBoxItem>
        <ComboBoxItem>arm</ComboBoxItem>
        <ComboBoxItem>all</ComboBoxItem>
      </ComboBox>
      <CheckBox x:Name="chkExtract" Margin="20,0,0,0" IsChecked="True"
                Content="This architecture only (skip the other slices of the bundle)"/>
      <CheckBox x:Name="chkDeps" Margin="20,0,0,0" IsChecked="True"
                Content="Include frameworks"/>
      <CheckBox x:Name="chkKit" Margin="20,0,0,0"
                Content="Offline kit (install.cmd for any PC)"/>
      <CheckBox x:Name="chkEncrypted" Margin="20,0,0,0"
                ToolTip="The Store also publishes some apps encrypted (.emsix/.eappx). They are the real, current build, but Windows only installs them on a machine holding the Store licence, so they are left out unless asked for."
                Content="Allow encrypted builds (.emsix - needs a Store licence)"/>
    </StackPanel>

    <StackPanel x:Name="gridBtns" Grid.Row="4" Orientation="Horizontal" Margin="0,14,0,0">
      <Button x:Name="btnDownload" Content="Download"           Style="{StaticResource BtnPrimary}" Margin="0,0,8,0"/>
      <Button x:Name="btnPreview"  Content="Preview"            Style="{StaticResource Btn}"        Margin="0,0,8,0"/>
      <Button x:Name="btnAll"      Content="Download + Install" Style="{StaticResource Btn}"        Margin="0,0,8,0"/>
      <Button x:Name="btnInstall"  Content="Install only"       Style="{StaticResource Btn}"        Margin="0,0,8,0"/>
      <Button x:Name="btnStop"     Content="Stop"               Style="{StaticResource BtnStop}"    Margin="0,0,8,0" IsEnabled="False"/>
      <Button x:Name="btnCheck"    Content="Check updates"      Style="{StaticResource BtnFlat}"    Margin="0,0,8,0"/>
      <Button x:Name="btnClear"    Content="Clear finished"     Style="{StaticResource BtnFlat}"/>
    </StackPanel>

    <Border x:Name="brdJobs" Grid.Row="5" Style="{StaticResource Card}" Margin="0,14,0,0"
            Height="250" Padding="3">
      <TabControl x:Name="tabJobs" Background="Transparent" BorderThickness="0"/>
    </Border>

  </Grid>
</Window>
'@

