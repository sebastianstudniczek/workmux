//! Shared dashboard geometry for rendering and mouse hit-testing.

use ratatui::layout::{Constraint, Layout, Rect};

use crate::config::DashboardLayout;

pub(super) fn dashboard_outer_areas(area: Rect) -> std::rc::Rc<[Rect]> {
    Layout::vertical([
        Constraint::Length(2),
        Constraint::Fill(1),
        Constraint::Length(1),
    ])
    .split(area)
}

/// Return the table and optional preview rectangles, independent of tab.
pub(super) fn dashboard_content_areas(
    content: Rect,
    supports_preview: bool,
    preview_size: u8,
    layout: DashboardLayout,
) -> (Rect, Option<Rect>) {
    if !supports_preview {
        return (content, None);
    }
    let preview_size = u16::from(preview_size);
    let table_size = 100u16.saturating_sub(preview_size);
    match layout {
        DashboardLayout::Stacked => {
            let chunks =
                Layout::vertical([Constraint::Fill(table_size), Constraint::Fill(preview_size)])
                    .split(content);
            (chunks[0], Some(chunks[1]))
        }
        DashboardLayout::SideBySide => {
            let chunks =
                Layout::horizontal([Constraint::Fill(preview_size), Constraint::Fill(table_size)])
                    .split(content);
            (chunks[1], Some(chunks[0]))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stacked_preserves_table_above_preview() {
        let content = Rect::new(5, 7, 100, 40);
        let (table, preview) = dashboard_content_areas(content, true, 60, DashboardLayout::Stacked);
        assert_eq!(table, Rect::new(5, 7, 100, 16));
        assert_eq!(preview, Some(Rect::new(5, 23, 100, 24)));
    }

    #[test]
    fn side_by_side_places_full_height_preview_on_left() {
        let content = Rect::new(5, 7, 100, 40);
        let (table, preview) =
            dashboard_content_areas(content, true, 60, DashboardLayout::SideBySide);
        assert_eq!(table, Rect::new(65, 7, 40, 40));
        assert_eq!(preview, Some(Rect::new(5, 7, 60, 40)));
    }

    #[test]
    fn unsupported_preview_uses_all_content() {
        let content = Rect::new(5, 7, 100, 40);
        for layout in [DashboardLayout::Stacked, DashboardLayout::SideBySide] {
            assert_eq!(
                dashboard_content_areas(content, false, 60, layout),
                (content, None)
            );
        }
    }

    #[test]
    fn splits_fit_small_and_empty_areas() {
        for width in [0, 1, 2, 20, 80] {
            for height in [0, 1, 2, 24] {
                for size in [10, 60, 90] {
                    for layout in [DashboardLayout::Stacked, DashboardLayout::SideBySide] {
                        let content = Rect::new(5, 7, width, height);
                        let (table, preview) = dashboard_content_areas(content, true, size, layout);
                        let preview = preview.unwrap();
                        for area in [table, preview] {
                            assert!(area.x >= content.x && area.y >= content.y);
                            assert!(area.right() <= content.right());
                            assert!(area.bottom() <= content.bottom());
                        }
                        match layout {
                            DashboardLayout::Stacked => {
                                assert_eq!(table.bottom(), preview.y);
                                assert_eq!(table.height + preview.height, height);
                            }
                            DashboardLayout::SideBySide => {
                                assert_eq!(preview.right(), table.x);
                                assert_eq!(table.width + preview.width, width);
                            }
                        }
                    }
                }
            }
        }
    }
}
